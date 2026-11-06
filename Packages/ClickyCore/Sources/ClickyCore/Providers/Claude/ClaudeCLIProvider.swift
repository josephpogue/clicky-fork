import Foundation

/// Answers questions through the official `claude` command line tool on the user's own subscription login.
/// One long-lived process serves the whole session, so follow-up questions are fast and remember the screenshots.
public final class ClaudeCLIProvider: AnswerProvider {
    public let providerID: ProviderID = .claude
    private let engine: ClaudeConversationEngine

    public init(
        locations: AppDataLocations,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        answerTimeoutSeconds: Double = 90
    ) {
        // Writing to a child that already exited must fail with an error, not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        engine = ClaudeConversationEngine(
            locations: locations,
            explicitExecutableURL: executableURL,
            parentEnvironment: environment,
            answerTimeoutSeconds: answerTimeoutSeconds
        )
    }

    public func startConversation(instructions: String, model: String, recap: String?) async throws {
        try await engine.startConversation(instructions: instructions, model: model, recap: recap)
    }

    public func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        try await engine.ask(turn, model: model)
    }

    public func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        try await engine.summarize(text, instructions: instructions, model: model)
    }

    public func endConversation() async {
        await engine.endConversation()
    }
}

/// What came back for one user message.
private struct ClaudeTurnResult {
    var text: String
    var secondsToAnswer: Double
}

/// Owns the child process and the record of this provider's own turns. An actor, so questions run one at a time
/// while `endConversation` can still step in when an answer is stuck.
actor ClaudeConversationEngine {
    private let locations: AppDataLocations
    private let explicitExecutableURL: URL?
    private let parentEnvironment: [String: String]
    private let answerTimeoutSeconds: Double

    private var activeProcess: ClaudeConversationProcess?
    private var hasStartedConversation = false
    private var instructions = ""
    /// The recap `startConversation` was given, kept so a restart can repeat it.
    private var openingRecap: String?
    /// Question and answer text of every turn this provider answered, for rebuilding the conversation after a restart.
    private var answeredTurns: [(question: String, answer: String)] = []
    /// Earlier-turns text a freshly restarted process has not been told yet; it rides on the next question.
    private var recapWaitingForNextQuestion: String?
    private var nextControlRequestNumber = 0
    /// Moves on every `startConversation` and `endConversation`. A question remembers the number it started under
    /// and refuses to go on once it has moved, because the actor is re-entered whenever a question waits.
    private var conversationGeneration = 0

    private static let modelChangeTimeoutSeconds = 10.0
    private static let gracePeriodSeconds = 1.0

    init(
        locations: AppDataLocations,
        explicitExecutableURL: URL?,
        parentEnvironment: [String: String],
        answerTimeoutSeconds: Double
    ) {
        self.locations = locations
        self.explicitExecutableURL = explicitExecutableURL
        self.parentEnvironment = parentEnvironment
        self.answerTimeoutSeconds = answerTimeoutSeconds
    }

    // MARK: Conversation

    func startConversation(instructions: String, model: String, recap: String?) async throws {
        conversationGeneration += 1
        let generation = conversationGeneration
        await stopActiveProcess(gracePeriodSeconds: Self.gracePeriodSeconds)
        // Another start or a Stop ran while the old process was being stopped: that call owns the state now.
        try refuseWhenConversationMoved(since: generation)
        self.instructions = instructions
        openingRecap = recap
        answeredTurns = []
        // Nothing is sent to Claude here: starting the process sends nothing, and the recap rides on the first
        // question, so nothing goes to any AI between questions.
        recapWaitingForNextQuestion = recap
        hasStartedConversation = true

        _ = try launchProcess(model: model, generation: generation)
    }

    func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        guard hasStartedConversation else {
            throw ProviderFailure.failed(message: "Claude is not started yet.")
        }

        let generation = conversationGeneration
        let process = try await processReady(forModel: model, generation: generation)
        // Nothing suspends between this check and the send, so a Stop cannot slip in between them.
        try refuseWhenConversationMoved(since: generation)

        var contentBlocks: [[String: Any]] = []
        if let recapText = recapWaitingForNextQuestion {
            contentBlocks.append(Self.textBlock(recapText))
        }
        for image in turn.images {
            contentBlocks.append(Self.textBlock(image.label))
            contentBlocks.append(try Self.imageBlock(for: image))
        }
        if !turn.contextNote.isEmpty {
            contentBlocks.append(Self.textBlock(turn.contextNote))
        }
        contentBlocks.append(Self.textBlock("Question: \(turn.questionText)"))

        try process.send(Self.userLine(content: contentBlocks))
        recapWaitingForNextQuestion = nil
        let result = try await waitForResult(from: process)
        try refuseWhenConversationMoved(since: generation)

        answeredTurns.append((question: turn.questionText, answer: result.text))
        return ProviderAnswer(text: result.text, model: model, secondsToAnswer: result.secondsToAnswer)
    }

    func endConversation() async {
        conversationGeneration += 1
        hasStartedConversation = false
        await stopActiveProcess(gracePeriodSeconds: Self.gracePeriodSeconds)
    }

    // MARK: Summary

    func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        let executableURL = try ClaudeCommandLine.resolveExecutable(explicit: explicitExecutableURL, environment: parentEnvironment)
        try? locations.createDirectories()
        let output = try await ClaudeOneShotRunner.run(
            executableURL: executableURL,
            arguments: ClaudeCommandLine.oneShotArguments(model: model, instructions: instructions),
            environment: ClaudeCommandLine.childEnvironment(base: parentEnvironment, locations: locations),
            workingDirectory: locations.providerWorkingDirectory,
            standardInputText: text,
            timeoutSeconds: answerTimeoutSeconds
        )
        if output.didTimeOut {
            throw ProviderFailure.failed(message: "Claude took too long to answer.")
        }
        if output.exitCode != 0 {
            throw ClaudeCommandLine.classifyFailure(
                text: output.standardOutput + "\n" + output.standardError,
                assistantErrorKind: nil
            )
        }
        return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Process lifecycle

    /// Throws when Stop or a new conversation ran since `generation` was taken, so a question that was waiting
    /// never starts a process or sends a line for a conversation that is over.
    private func refuseWhenConversationMoved(since generation: Int) throws {
        if generation != conversationGeneration {
            throw ProviderFailure.failed(message: "The question was stopped.")
        }
    }

    private func launchProcess(model: String, generation: Int) throws -> ClaudeConversationProcess {
        // The last gate before a process exists: no await sits between this check and the launch.
        try refuseWhenConversationMoved(since: generation)
        let executableURL = try ClaudeCommandLine.resolveExecutable(explicit: explicitExecutableURL, environment: parentEnvironment)
        try? locations.createDirectories()
        let process = try ClaudeConversationProcess(
            executableURL: executableURL,
            arguments: ClaudeCommandLine.conversationArguments(model: model, instructions: instructions),
            environment: ClaudeCommandLine.childEnvironment(base: parentEnvironment, locations: locations),
            workingDirectory: locations.providerWorkingDirectory,
            model: model
        )
        activeProcess = process
        return process
    }

    private func stopActiveProcess(gracePeriodSeconds: Double) async {
        guard let process = activeProcess else { return }
        activeProcess = nil
        await process.stop(gracePeriodSeconds: gracePeriodSeconds)
    }

    /// A running process answering with `model`: the current one, the current one switched in place,
    /// or a fresh one seeded with the earlier turns as text.
    private func processReady(forModel model: String, generation: Int) async throws -> ClaudeConversationProcess {
        guard let process = activeProcess, process.isRunning else {
            await stopActiveProcess(gracePeriodSeconds: 0)
            return try restartSeededWithEarlierTurns(model: model, generation: generation)
        }
        if process.model == model { return process }

        let changedInPlace = await changeModelInPlace(of: process, to: model)
        // Stop during the wait kills the process, which reads as a refused change; it must not restart one.
        try refuseWhenConversationMoved(since: generation)
        if changedInPlace {
            return process
        }
        await stopActiveProcess(gracePeriodSeconds: 0.2)
        return try restartSeededWithEarlierTurns(model: model, generation: generation)
    }

    private func restartSeededWithEarlierTurns(model: String, generation: Int) throws -> ClaudeConversationProcess {
        try refuseWhenConversationMoved(since: generation)
        recapWaitingForNextQuestion = recapOfEarlierTurns()
        return try launchProcess(model: model, generation: generation)
    }

    /// Asks the running tool to switch models (the same `set_model` request the Claude Agent SDK sends).
    private func changeModelInPlace(of process: ClaudeConversationProcess, to model: String) async -> Bool {
        nextControlRequestNumber += 1
        let requestID = "clicky-model-\(nextControlRequestNumber)"
        let request: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": ["subtype": "set_model", "model": model],
        ]
        guard (try? process.send(request)) != nil else { return false }

        let deadline = Date().addingTimeInterval(Self.modelChangeTimeoutSeconds)
        while true {
            let event = await process.lines.nextEvent(timeoutSeconds: deadline.timeIntervalSinceNow)
            guard case .line(let line) = event else { return false }
            guard let message = Self.parse(line), message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else {
                continue
            }
            if response["subtype"] as? String == "success" {
                process.model = model
                return true
            }
            return false
        }
    }

    /// "Earlier in this session" text from the opening recap plus every turn this provider answered.
    private func recapOfEarlierTurns() -> String? {
        var parts: [String] = []
        if let openingRecap { parts.append(openingRecap) }
        if !answeredTurns.isEmpty {
            let turnsText = answeredTurns
                .map { "Question: \($0.question)\nAnswer: \($0.answer)" }
                .joined(separator: "\n\n")
            parts.append("Earlier in this session:\n\(turnsText)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Reading one turn

    /// Reads lines until this turn's `result`. Every turn prints its own `system`/`init` line, which is where
    /// the login kind is checked, so an API-key login is caught on the first message sent.
    private func waitForResult(from process: ClaudeConversationProcess) async throws -> ClaudeTurnResult {
        let startedAt = ContinuousClock.now
        let deadline = Date().addingTimeInterval(answerTimeoutSeconds)
        var assistantErrorKind: String?

        while true {
            let event = await process.lines.nextEvent(timeoutSeconds: deadline.timeIntervalSinceNow)
            switch event {
            case .timedOut:
                await dropProcess(process)
                throw ProviderFailure.failed(message: "Claude took too long to answer.")
            case .ended:
                await dropProcess(process)
                throw ProviderFailure.failed(message: "Claude stopped before answering.")
            case .line(let line):
                guard let message = Self.parse(line) else { continue }
                switch message["type"] as? String {
                case "system":
                    if message["subtype"] as? String == "init",
                       let keySource = message["apiKeySource"] as? String, keySource != "none" {
                        await dropProcess(process)
                        throw ProviderFailure.notSubscriptionLogin(
                            detail: "Claude Code is using \(keySource) instead of your Claude subscription."
                        )
                    }
                case "assistant":
                    if let errorKind = message["error"] as? String { assistantErrorKind = errorKind }
                case "result":
                    let resultText = message["result"] as? String ?? ""
                    let subtype = message["subtype"] as? String ?? ""
                    let isError = message["is_error"] as? Bool ?? false
                    if isError || subtype.hasPrefix("error") {
                        throw ClaudeCommandLine.classifyFailure(text: resultText, assistantErrorKind: assistantErrorKind)
                    }
                    let elapsed = ContinuousClock.now - startedAt
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    return ClaudeTurnResult(text: resultText, secondsToAnswer: seconds)
                default:
                    continue
                }
            }
        }
    }

    private func dropProcess(_ process: ClaudeConversationProcess) async {
        if activeProcess === process { activeProcess = nil }
        await process.stop(gracePeriodSeconds: 0.2)
    }

    // MARK: Message building

    private static func parse(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func imageBlock(for image: TurnImage) throws -> [String: Any] {
        guard let imageBytes = try? Data(contentsOf: image.fileURL) else {
            throw ProviderFailure.failed(message: "A screenshot could not be read.")
        }
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": imageBytes.base64EncodedString(),
            ],
        ]
    }

    private static func userLine(content: [[String: Any]]) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": content]]
    }
}
