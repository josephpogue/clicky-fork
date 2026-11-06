import Foundation

/// Answers questions through the official `codex` tool on the user's own ChatGPT login.
///
/// One conversation is one Codex thread: the first question runs `codex exec`, later ones run
/// `codex exec resume <thread id>`, so the model remembers earlier screenshots. Instructions go in
/// as `developer_instructions` on every turn. Every run uses the app's own `CODEX_HOME`.
public final class CodexCLIProvider: AnswerProvider, @unchecked Sendable {
    public let providerID: ProviderID = .chatgpt

    private let setup: CodexCLISetup
    private let answerTimeoutSeconds: Double
    private let runner = CodexProcessRunner()

    private let stateLock = NSLock()
    private var instructions = ""
    private var threadID: String?
    private var hasCheckedLoginThisConversation = false
    /// Raised by `endConversation` and cleared by `startConversation`, so an answer that arrives after Stop is dropped.
    private var conversationGeneration = 0

    public init(
        locations: AppDataLocations,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        answerTimeoutSeconds: Double = 120
    ) {
        setup = CodexCLISetup(locations: locations, executableURLOverride: executableURL, parentEnvironment: environment)
        self.answerTimeoutSeconds = answerTimeoutSeconds
    }

    // MARK: AnswerProvider

    public func startConversation(instructions: String, model: String, recap: String?) async throws {
        runner.terminateEverything()
        let generation = withState { () -> Int in
            self.instructions = instructions
            threadID = nil
            hasCheckedLoginThisConversation = false
            conversationGeneration += 1
            return conversationGeneration
        }
        guard let recap else { return }

        // The new thread starts with the recap as its first turn, so later questions can refer to what came before.
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        try await checkSubscriptionLoginOnce(executableURL: executableURL)
        let recapPrompt = "Earlier in this session: \(recap)\n\nThis is background only. Reply with just: OK"
        let output = try await runTurn(
            executableURL: executableURL,
            prompt: recapPrompt,
            imagePaths: [],
            model: model,
            instructions: instructions,
            threadIDToResume: nil,
            keepsThread: true,
            generation: generation
        )
        recordThreadID(output.threadID, generation: generation)
    }

    public func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        try await checkSubscriptionLoginOnce(executableURL: executableURL)

        let startedAt = Date()
        let (currentInstructions, threadToResume, generation) = withState { (instructions, threadID, conversationGeneration) }
        let output = try await runTurn(
            executableURL: executableURL,
            prompt: CodexOutputParsing.promptText(for: turn),
            imagePaths: turn.images.map { $0.fileURL.path },
            model: model,
            instructions: currentInstructions,
            threadIDToResume: threadToResume,
            keepsThread: true,
            generation: generation
        )
        recordThreadID(output.threadID, generation: generation)

        let answerText = output.answerText ?? ""
        return ProviderAnswer(
            text: answerText,
            model: model,
            secondsToAnswer: Date().timeIntervalSince(startedAt)
        )
    }

    public func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        try await checkSubscriptionLoginOnce(executableURL: executableURL)

        let generation = withState { conversationGeneration }
        // A one-off run: `--ephemeral` keeps no session on disk, and the thread id is not stored.
        let output = try await runTurn(
            executableURL: executableURL,
            prompt: text,
            imagePaths: [],
            model: model,
            instructions: instructions,
            threadIDToResume: nil,
            keepsThread: false,
            generation: generation
        )
        return output.answerText ?? ""
    }

    public func endConversation() async {
        let threadToDelete = withState { () -> String? in
            let finishedThreadID = threadID
            threadID = nil
            hasCheckedLoginThisConversation = false
            conversationGeneration += 1
            return finishedThreadID
        }
        runner.terminateEverything()
        // Codex keeps every thread, with its screenshots, in the app's CODEX_HOME. Remove this one so they do not pile up.
        guard let threadToDelete, let executableURL = try? setup.resolveExecutable() else { return }
        _ = await runner.run(
            executableURL: executableURL,
            arguments: ["delete", "--force", threadToDelete],
            environment: setup.childEnvironment,
            workingDirectory: setup.locations.providerWorkingDirectory,
            timeoutSeconds: 15
        )
    }

    // MARK: Running a turn

    private func runTurn(
        executableURL: URL,
        prompt: String,
        imagePaths: [String],
        model: String,
        instructions: String,
        threadIDToResume: String?,
        keepsThread: Bool,
        generation: Int
    ) async throws -> CodexTurnOutput {
        let arguments = buildArguments(
            prompt: prompt,
            imagePaths: imagePaths,
            model: model,
            instructions: instructions,
            threadIDToResume: threadIDToResume,
            keepsThread: keepsThread
        )
        let result = await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: setup.childEnvironment,
            workingDirectory: setup.locations.providerWorkingDirectory,
            timeoutSeconds: answerTimeoutSeconds,
            shouldStopAfterLine: { CodexOutputParsing.lineShowsRejectedLogin($0) }
        )

        if result.couldNotStart { throw ProviderFailure.cliNotFound }
        if result.wasCancelled || withState({ conversationGeneration }) != generation {
            throw ProviderFailure.failed(message: "The question was stopped.")
        }

        let output = CodexOutputParsing.parseTurnOutput(lines: result.outputLines)
        if result.wasStoppedEarly {
            throw ProviderFailure.notSignedIn
        }
        if result.didTimeOut {
            throw ProviderFailure.failed(message: "ChatGPT took too long to answer.")
        }
        if output.turnFailedMessage != nil || output.answerText == nil {
            if output.turnCompleted, output.answerText == nil {
                throw ProviderFailure.failed(message: "ChatGPT sent back an empty answer.")
            }
            throw CodexOutputParsing.classifyFailure(
                messages: output.errorMessages,
                standardErrorText: result.standardErrorText
            )
        }
        return output
    }

    /// First turn: `exec ... "<prompt>" -i a -i b`. Later turns: `exec resume ... <thread id> "<prompt>" -i a`.
    /// The prompt comes before the first `-i` because `-i` takes every value that follows it.
    private func buildArguments(
        prompt: String,
        imagePaths: [String],
        model: String,
        instructions: String,
        threadIDToResume: String?,
        keepsThread: Bool
    ) -> [String] {
        var arguments = ["exec"]
        if threadIDToResume != nil {
            arguments.append("resume")
        }
        arguments += ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"]
        if threadIDToResume == nil {
            // `exec resume` has neither -s nor -C; it takes the sandbox from -c and the folder from the process.
            arguments += ["-s", "read-only", "-C", setup.locations.providerWorkingDirectory.path]
        } else {
            arguments += ["-c", "sandbox_mode=\"read-only\""]
        }
        if !keepsThread {
            arguments.append("--ephemeral")
        }
        // An empty model name is the settings default: leave the choice to Codex.
        if !model.isEmpty {
            arguments += ["-m", model]
        }
        // Low effort answers screen questions as well as medium, with no reasoning tokens spent.
        arguments += ["-c", "model_reasoning_effort=low"]
        if !instructions.isEmpty {
            arguments += ["-c", "developer_instructions=\(CodexOutputParsing.tomlBasicString(instructions))"]
        }
        if let threadIDToResume {
            arguments.append(threadIDToResume)
        }
        arguments.append(CodexOutputParsing.safePromptArgument(prompt))
        for imagePath in imagePaths {
            arguments += ["-i", imagePath]
        }
        return arguments
    }

    // MARK: Login check

    /// Reads `codex login status` once per conversation, so an API key login is refused before any question is sent
    /// and a missing login is reported at once instead of after the CLI's long retry loop.
    private func checkSubscriptionLoginOnce(executableURL: URL) async throws {
        let alreadyChecked = withState { hasCheckedLoginThisConversation }
        if alreadyChecked { return }
        let state = await setup.readLoginState(runner: runner, executableURL: executableURL)
        switch state {
        case .chatGPT, .unknown:
            withState { hasCheckedLoginThisConversation = true }
        case .notLoggedIn:
            throw ProviderFailure.notSignedIn
        case .otherLogin(let detail):
            throw ProviderFailure.notSubscriptionLogin(detail: detail)
        }
    }

    // MARK: State

    private func recordThreadID(_ newThreadID: String?, generation: Int) {
        withState {
            // An answer from before Stop or a new conversation must not become the current thread.
            if generation == conversationGeneration, let newThreadID {
                threadID = newThreadID
            }
        }
    }

    private func withState<Result>(_ body: () -> Result) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
