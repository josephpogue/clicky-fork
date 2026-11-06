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
        await stopActiveProcess(gracePeriodSeconds: Self.gracePeriodSeconds)
        self.instructions = instructions
        openingRecap = recap
        answeredTurns = []
        recapWaitingForNextQuestion = nil
        hasStartedConversation = true

        let process = try launchProcess(model: model)
        guard let recap else { return }

        // The recap is a real first message, so the tool has taken it in (and the login has been checked)
        // before the first question arrives.
        try process.send(Self.userLine(content: [Self.textBlock(recap)]))
        _ = try await waitForResult(from: process)
    }

    func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        guard hasStartedConversation else {
            throw ProviderFailure.failed(message: "Claude is not started yet.")
        }

        let process = try await processReady(forModel: model)

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

        answeredTurns.append((question: turn.questionText, answer: result.text))
        return ProviderAnswer(text: result.text, model: model, secondsToAnswer: result.secondsToAnswer)
    }

    func endConversation() async {
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

    private func launchProcess(model: String) throws -> ClaudeConversationProcess {
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
    private func processReady(forModel model: String) async throws -> ClaudeConversationProcess {
        guard let process = activeProcess, process.isRunning else {
            await stopActiveProcess(gracePeriodSeconds: 0)
            return try restartSeededWithEarlierTurns(model: model)
        }
        if process.model == model { return process }

        if await changeModelInPlace(of: process, to: model) {
            return process
        }
        await stopActiveProcess(gracePeriodSeconds: 0.2)
        return try restartSeededWithEarlierTurns(model: model)
    }

    private func restartSeededWithEarlierTurns(model: String) throws -> ClaudeConversationProcess {
        recapWaitingForNextQuestion = recapOfEarlierTurns()
        return try launchProcess(model: model)
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
