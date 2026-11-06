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
    /// True between `startConversation` and `endConversation`. A question outside that span is refused.
    private var isConversationRunning = false
    /// The recap `startConversation` was given. It rides on the first question, before any thread exists, so nothing
    /// is sent between questions. Cleared once a turn that carried it has been answered.
    private var recapWaitingForFirstQuestion: String?
    /// Raised by `startConversation` and `endConversation`, so a question that was started under an older number
    /// (and an answer that arrives after Stop) is dropped.
    private var conversationGeneration = 0
    /// True while `answer` is running a question. `stopCurrentAnswer` only acts then.
    private var isAnswerInFlight = false
    /// Raised by `stopCurrentAnswer` for the answer in flight, so even an answer whose `exec` has not started yet
    /// (the login check is still running) ends at once with what it has.
    private var isStopOfCurrentAnswerRequested = false

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
        withState {
            self.instructions = instructions
            threadID = nil
            hasCheckedLoginThisConversation = false
            isConversationRunning = true
            recapWaitingForFirstQuestion = recap
            conversationGeneration += 1
        }
        // No CLI call here: the recap goes out ahead of the first question, in the same turn.
    }

    public func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        try await answer(turn, request: AnswerRequest(model: model), progress: { _ in })
    }

    /// `request.model` and `request.effort` apply to this one `exec` only: nothing is stored, so the next normal
    /// question is back to the settings model and low effort. Passages in `turn.brainNote` ride in the prompt;
    /// ChatGPT gets no tools (see `CodexToolRestrictions`).
    public func answer(
        _ turn: QuestionTurn,
        request: AnswerRequest,
        progress: @escaping @Sendable (AnswerProgress) async -> Void
    ) async throws -> ProviderAnswer {
        // Taken before anything is awaited, so a Stop during the login check below still cancels this question.
        let (generation, isRunning) = withState { (conversationGeneration, isConversationRunning) }
        guard isRunning else {
            throw ProviderFailure.failed(message: "ChatGPT is not started yet.")
        }
        withState {
            isAnswerInFlight = true
            isStopOfCurrentAnswerRequested = false
        }
        defer {
            withState {
                isAnswerInFlight = false
                isStopOfCurrentAnswerRequested = false
            }
        }
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        try await checkSubscriptionLoginOnce(executableURL: executableURL, generation: generation)

        let startedAt = Date()
        let (currentInstructions, threadToResume, recapToSend) = withState { (instructions, threadID, recapWaitingForFirstQuestion) }
        // A recap is only needed while no thread holds the earlier turns.
        let recapForThisTurn = threadToResume == nil ? recapToSend : nil

        // The reader thread reports each agent message into this stream; one task awaits `progress` in order.
        let (textStream, textContinuation) = AsyncStream.makeStream(of: String.self)
        let progressTask = Task {
            for await textSoFar in textStream {
                await progress(.textSoFar(textSoFar))
            }
        }
        let liveTurn = CodexLiveTurn(onTextSoFar: { textContinuation.yield($0) })
        let output: CodexTurnOutput
        let wasCutShort: Bool
        do {
            (output, wasCutShort) = try await runTurn(
                executableURL: executableURL,
                prompt: CodexOutputParsing.promptText(for: turn, recap: recapForThisTurn),
                imagePaths: turn.images.map { $0.fileURL.path },
                model: request.model,
                effort: request.effort?.rawValue ?? "low",
                instructions: currentInstructions,
                threadIDToResume: threadToResume,
                keepsThread: true,
                endsOnStopOfCurrentAnswer: true,
                liveTurn: liveTurn,
                generation: generation
            )
        } catch {
            textContinuation.finish()
            await progressTask.value
            throw error
        }
        textContinuation.finish()
        await progressTask.value

        if wasCutShort {
            // The question was ended on purpose. Whether the thread of the ended run is kept is decided in
            // `threadToKeepAfterEndedAnswer`; the recap stays pending only when no thread exists to hold it.
            recordThreadID(Self.threadToKeepAfterEndedAnswer(
                threadBeforeThisQuestion: threadToResume, threadOfEndedRun: output.threadID
            ), generation: generation)
        } else {
            recordThreadID(output.threadID, generation: generation)
        }
        if recapForThisTurn != nil, withState({ threadID }) != nil {
            withState {
                if generation == conversationGeneration { recapWaitingForFirstQuestion = nil }
            }
        }

        return ProviderAnswer(
            text: output.answerText ?? "",
            model: request.model,
            secondsToAnswer: Date().timeIntervalSince(startedAt),
            secondsToFirstText: liveTurn.secondsToFirstText,
            wasCutShort: wasCutShort
        )
    }

    /// Ends the exec that is running, if any. The pending `answer` returns the agent text so far, cut short, and the
    /// conversation stays open for the next question.
    public func stopCurrentAnswer() async {
        let shouldEnd = withState { () -> Bool in
            guard isAnswerInFlight else { return false }
            isStopOfCurrentAnswerRequested = true
            return true
        }
        if shouldEnd { runner.endRunningProcesses() }
    }

    public func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        let executableURL = try setup.resolveExecutable()
        try setup.prepareDirectories()
        let generation = withState { conversationGeneration }
        try await checkSubscriptionLoginOnce(executableURL: executableURL, generation: generation)

        // A one-off run: `--ephemeral` keeps no session on disk, and the thread id is not stored.
        return try await runTurn(
            executableURL: executableURL,
            prompt: text,
            imagePaths: [],
            model: model,
            effort: "low",
            instructions: instructions,
            threadIDToResume: nil,
            keepsThread: false,
            endsOnStopOfCurrentAnswer: false,
            liveTurn: CodexLiveTurn(onTextSoFar: { _ in }),
            generation: generation
        ).output.answerText ?? ""
    }

    public func endConversation() async {
        let threadToDelete = withState { () -> String? in
            let finishedThreadID = threadID
            threadID = nil
            hasCheckedLoginThisConversation = false
            isConversationRunning = false
            recapWaitingForFirstQuestion = nil
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

    /// Runs one `exec`. Returns the parsed output and whether the answer was ended on purpose (`stopCurrentAnswer`),
    /// in which case the output holds the agent messages that had arrived.
    private func runTurn(
        executableURL: URL,
        prompt: String,
        imagePaths: [String],
        model: String,
        effort: String,
        instructions: String,
        threadIDToResume: String?,
        keepsThread: Bool,
        endsOnStopOfCurrentAnswer: Bool,
        liveTurn: CodexLiveTurn,
        generation: Int
    ) async throws -> (output: CodexTurnOutput, wasCutShort: Bool) {
        // Stop may have landed while the login check or the previous step was awaited.
        if withState({ conversationGeneration }) != generation {
            throw ProviderFailure.failed(message: "The question was stopped.")
        }
        let arguments = buildArguments(
            prompt: prompt,
            imagePaths: imagePaths,
            model: model,
            effort: effort,
            instructions: instructions,
            threadIDToResume: threadIDToResume,
            keepsThread: keepsThread
        )
        liveTurn.markLaunch()
        let result = await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: setup.childEnvironment,
            workingDirectory: setup.locations.providerWorkingDirectory,
            timeoutSeconds: answerTimeoutSeconds,
            shouldStopAfterLine: { CodexOutputParsing.lineShowsRejectedLogin($0) },
            onLine: { liveTurn.take(line: $0) },
            shouldStillStart: { [self] in
                withState({
                    conversationGeneration == generation && !(endsOnStopOfCurrentAnswer && isStopOfCurrentAnswerRequested)
                })
            }
        )

        if result.couldNotStart { throw ProviderFailure.cliNotFound }
        // Stop or a new conversation always fails the question, even when a newer answer stop was also asked.
        if withState({ conversationGeneration }) != generation {
            throw ProviderFailure.failed(message: "The question was stopped.")
        }
        if endsOnStopOfCurrentAnswer,
           result.wasEndedOnRequest || withState({ isStopOfCurrentAnswerRequested }) {
            // Ended on purpose (a new question): hand back what had arrived. The live turn saw every complete line,
            // including lines the process printed just before it ended.
            var cutShortOutput = CodexTurnOutput()
            cutShortOutput.agentMessages = liveTurn.agentMessages
            cutShortOutput.threadID = liveTurn.threadID
            return (cutShortOutput, true)
        }
        if result.wasCancelled {
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
        return (output, false)
    }

    /// Which thread the conversation resumes after an answer was ended mid-way.
    static func threadToKeepAfterEndedAnswer(threadBeforeThisQuestion: String?, threadOfEndedRun: String?) -> String? {
        threadOfEndedRun ?? threadBeforeThisQuestion
    }

    /// First turn: `exec ... "<prompt>" -i a -i b`. Later turns: `exec resume ... <thread id> "<prompt>" -i a`.
    /// The prompt comes before the first `-i` because `-i` takes every value that follows it.
    private func buildArguments(
        prompt: String,
        imagePaths: [String],
        model: String,
        effort: String,
        instructions: String,
        threadIDToResume: String?,
        keepsThread: Bool
    ) -> [String] {
        var arguments = ["exec"]
        if threadIDToResume != nil {
            arguments.append("resume")
        }
        arguments += ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"]
        // Every tool the model could use is off, on the first turn and on every resume.
        arguments += CodexToolRestrictions.arguments
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
        // Low effort answers screen questions as well as medium, with no reasoning tokens spent. Dig deeper asks
        // for a stronger effort for its one exec.
        arguments += ["-c", "model_reasoning_effort=\(effort)"]
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
    private func checkSubscriptionLoginOnce(executableURL: URL, generation: Int) async throws {
        let alreadyChecked = withState { hasCheckedLoginThisConversation }
        if alreadyChecked { return }
        let state = await setup.readLoginState(
            runner: runner,
            executableURL: executableURL,
            shouldStillStart: { [self] in withState({ conversationGeneration }) == generation }
        )
        // Stop killed the check (or landed during it): the question is over, whatever the check said.
        if state == .cancelled || withState({ conversationGeneration }) != generation {
            throw ProviderFailure.failed(message: "The question was stopped.")
        }
        switch state {
        case .chatGPT, .unknown:
            withState { hasCheckedLoginThisConversation = true }
        case .notLoggedIn:
            throw ProviderFailure.notSignedIn
        case .otherLogin(let detail):
            throw ProviderFailure.notSubscriptionLogin(detail: detail)
        case .cancelled:
            throw ProviderFailure.failed(message: "The question was stopped.")
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

/// What one running `exec` has printed so far, read from the reader thread as each line arrives.
final class CodexLiveTurn: @unchecked Sendable {
    private let lock = NSLock()
    private let onTextSoFar: @Sendable (String) -> Void
    private var launchedAt = Date()
    private var firstTextAt: Date?
    private var messages: [String] = []
    private var recordedThreadID: String?

    init(onTextSoFar: @escaping @Sendable (String) -> Void) {
        self.onTextSoFar = onTextSoFar
    }

    /// Called just before the `exec` is launched.
    func markLaunch() {
        lock.lock(); launchedAt = Date(); lock.unlock()
    }

    func take(line: String) {
        if let newThreadID = CodexOutputParsing.threadID(inLine: line) {
            lock.lock(); recordedThreadID = newThreadID; lock.unlock()
            return
        }
        guard let messageText = CodexOutputParsing.agentMessageText(inLine: line) else { return }
        lock.lock()
        messages.append(messageText)
        if firstTextAt == nil { firstTextAt = Date() }
        let textSoFar = CodexOutputParsing.joinedAgentMessages(messages)
        lock.unlock()
        onTextSoFar(textSoFar)
    }

    var agentMessages: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    var threadID: String? { lock.lock(); defer { lock.unlock() }; return recordedThreadID }

    /// Seconds from launching the exec to the first agent message; nil when none came.
    var secondsToFirstText: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let firstTextAt else { return nil }
        return firstTextAt.timeIntervalSince(launchedAt)
    }
}
