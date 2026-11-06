import Foundation

/// Answers questions through the official `claude` command line tool on the user's own subscription login.
/// One long-lived process serves the whole session, so follow-up questions are fast and remember the screenshots.
public final class ClaudeCLIProvider: AnswerProvider {
    public let providerID: ProviderID = .claude
    private let engine: ClaudeConversationEngine
    /// How many `answer` calls have started and not yet returned to their caller.
    let answersInside = ClaudeAnswersInside()

    public init(
        locations: AppDataLocations,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        answerTimeoutSeconds: Double = 90,
        brainToolServer: BrainToolServer? = nil,
        interruptGraceSeconds: Double = 5
    ) {
        // Writing to a child that already exited must fail with an error, not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        engine = ClaudeConversationEngine(
            locations: locations,
            explicitExecutableURL: executableURL,
            parentEnvironment: environment,
            answerTimeoutSeconds: answerTimeoutSeconds,
            brainToolServer: brainToolServer,
            interruptGraceSeconds: interruptGraceSeconds
        )
        supportsBrainTools = brainToolServer != nil
    }

    /// True when the model can search and read the user's notes through the bundled helper.
    public let supportsBrainTools: Bool

    public func startConversation(instructions: String, model: String, recap: String?) async throws {
        try await engine.startConversation(instructions: instructions, model: model, recap: recap)
    }

    public func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        try await engine.answer(turn, request: AnswerRequest(model: model), progress: { _ in })
    }

    public func answer(
        _ turn: QuestionTurn,
        request: AnswerRequest,
        progress: @escaping @Sendable (AnswerProgress) async -> Void
    ) async throws -> ProviderAnswer {
        answersInside.enter()
        defer { answersInside.leave() }
        return try await engine.answer(turn, request: request, progress: progress)
    }

    /// Returns only once the answer that was running has returned, so a caller that shows the cut answer never
    /// sees the stop finish first.
    public func stopCurrentAnswer() async {
        await engine.stopCurrentAnswer()
        await answersInside.waitUntilNoneInside(seconds: 2)
    }

    public func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        try await engine.summarize(text, instructions: instructions, model: model)
    }

    public func endConversation() async {
        await engine.endConversation()
    }
}

/// Counts the `answer` calls that have not returned yet, so `stopCurrentAnswer` can wait for the last line of the
/// answer it ended and not only for the engine to finish reading.
final class ClaudeAnswersInside: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func enter() { lock.lock(); count += 1; lock.unlock() }
    func leave() { lock.lock(); count -= 1; lock.unlock() }
    var numberInside: Int { lock.lock(); defer { lock.unlock() }; return count }

    func waitUntilNoneInside(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while numberInside > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// The answer being read right now. Only the engine touches it, always on its actor.
final class ClaudeRunningAnswer {
    var process: ClaudeConversationProcess?
    /// A new question, Stop or the repeat guard asked this answer to end early.
    var endedEarly = false
    /// The line carrying the question was written, so an interrupt means something to the tool.
    var userLineSent = false
    var interruptSent = false
    /// When the tool must have printed its `result` after an interrupt; past it the process is stopped.
    var interruptDeadline: Date?
    var isFinished = false
}

/// Owns the child process and the record of this provider's own turns. An actor, so questions run one at a time
/// while `endConversation` can still step in when an answer is stuck.
actor ClaudeConversationEngine {
    private let locations: AppDataLocations
    private let explicitExecutableURL: URL?
    private let parentEnvironment: [String: String]
    /// How long the tool may print nothing at all before the answer is given up. A streaming answer never hits it.
    private let answerTimeoutSeconds: Double
    private let brainToolServer: BrainToolServer?

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
    private var runningAnswer: ClaudeRunningAnswer?
    /// Moves on every `stopCurrentAnswer`. A question that waited for the earlier answer to end checks it, because
    /// a stop that came during the wait cancels this question too.
    private var stopRequestCount = 0

    private static let modelChangeTimeoutSeconds = 10.0
    /// How long an interrupted answer has to print its `result` before its process is stopped.
    private let interruptGraceSeconds: Double
    private static let gracePeriodSeconds = 1.0

    init(
        locations: AppDataLocations,
        explicitExecutableURL: URL?,
        parentEnvironment: [String: String],
        answerTimeoutSeconds: Double,
        brainToolServer: BrainToolServer?,
        interruptGraceSeconds: Double
    ) {
        self.brainToolServer = brainToolServer
        self.interruptGraceSeconds = interruptGraceSeconds
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

    func answer(
        _ turn: QuestionTurn,
        request: AnswerRequest,
        progress: @escaping @Sendable (AnswerProgress) async -> Void
    ) async throws -> ProviderAnswer {
        guard hasStartedConversation else {
            throw ProviderFailure.failed(message: "Claude is not started yet.")
        }

        let generation = conversationGeneration
        let stopRequestsAtEntry = stopRequestCount
        // Two answers must never share the process: the earlier one ends first.
        if runningAnswer != nil { await endRunningAnswer() }
        try refuseWhenConversationMoved(since: generation)
        if stopRequestCount != stopRequestsAtEntry {
            // Stop (or a newer question's stop) came while this question waited: it ends before it is sent.
            return ProviderAnswer(text: "", model: request.model, secondsToAnswer: 0, wasCutShort: true)
        }
        let running = ClaudeRunningAnswer()
        runningAnswer = running
        defer {
            running.isFinished = true
            if runningAnswer === running { runningAnswer = nil }
        }

        var process = try await processReady(forModel: request.model, generation: generation)
        running.process = process
        try refuseWhenConversationMoved(since: generation)
        var effortWasSettled = await settleEffort(of: process, to: request.effort)
        try refuseWhenConversationMoved(since: generation)
        if !effortWasSettled && request.effort == nil && !running.endedEarly {
            // Putting the process back to its normal effort failed. Try once more; if it still fails the process
            // would keep answering on the stronger effort, so a fresh one (default effort) takes this question.
            effortWasSettled = await settleEffort(of: process, to: request.effort)
            try refuseWhenConversationMoved(since: generation)
            if !effortWasSettled && !running.endedEarly {
                await stopActiveProcess(gracePeriodSeconds: 0.2)
                try refuseWhenConversationMoved(since: generation)
                process = try restartSeededWithEarlierTurns(model: request.model, generation: generation)
                running.process = process
                effortWasSettled = true
            }
        }
        if running.endedEarly {
            // A newer question came before this one was even sent.
            return ProviderAnswer(text: "", model: request.model, secondsToAnswer: 0, wasCutShort: true)
        }

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
        if !turn.brainNote.isEmpty {
            contentBlocks.append(Self.textBlock(turn.brainNote))
        }
        contentBlocks.append(Self.textBlock("Question: \(turn.questionText)"))

        // Nothing suspends between the last generation check and the send, so a Stop cannot slip in between them.
        let startedAt = ContinuousClock.now
        try process.send(Self.userLine(content: contentBlocks))
        running.userLineSent = true
        recapWaitingForNextQuestion = nil

        let finished = try await readAnswer(
            from: process,
            running: running,
            generation: generation,
            startedAt: startedAt,
            progress: progress
        )
        try refuseWhenConversationMoved(since: generation)

        if !finished.text.isEmpty {
            answeredTurns.append((question: turn.questionText, answer: finished.text))
        }
        return ProviderAnswer(
            text: finished.text,
            model: request.model,
            secondsToAnswer: finished.secondsToAnswer,
            secondsToFirstText: finished.secondsToFirstText,
            toolCalls: finished.toolCalls,
            notesRead: finished.notesRead,
            toolResultCharacterCount: finished.toolResultCharacterCount,
            wasCutShort: finished.wasCutShort,
            effortWasApplied: request.effort == nil ? nil : effortWasSettled
        )
    }

    /// Ends the answer under way: the tool is asked to interrupt, the pending `answer` call returns the text that
    /// had arrived, and the process stays open for the next question. Returns once that answer is over.
    func stopCurrentAnswer() async {
        stopRequestCount += 1
        await endRunningAnswer()
    }

    /// The part of a stop that ends the running answer. A question waiting for the earlier answer uses it too,
    /// without counting as a stop.
    private func endRunningAnswer() async {
        guard let running = runningAnswer, !running.isFinished else { return }
        running.endedEarly = true
        if running.userLineSent, let process = running.process {
            sendInterrupt(for: running, to: process)
        }
        // The answer's own loop returns on the interrupted `result`; past the grace period the process is
        // stopped and the next question starts a fresh one seeded with the earlier turns.
        await waitUntilFinished(running, seconds: interruptGraceSeconds)
        if !running.isFinished, let process = running.process {
            await dropProcess(process)
        }
        await waitUntilFinished(running, seconds: 3)
    }

    private func waitUntilFinished(_ running: ClaudeRunningAnswer, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !running.isFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func sendInterrupt(for running: ClaudeRunningAnswer, to process: ClaudeConversationProcess) {
        guard !running.interruptSent else { return }
        running.interruptSent = true
        running.interruptDeadline = Date().addingTimeInterval(interruptGraceSeconds)
        nextControlRequestNumber += 1
        let request: [String: Any] = [
            "type": "control_request",
            "request_id": "clicky-interrupt-\(nextControlRequestNumber)",
            "request": ["subtype": "interrupt"],
        ]
        try? process.send(request)
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
            arguments: ClaudeCommandLine.conversationArguments(
                model: model,
                instructions: instructions,
                brainToolServer: brainToolServer
            ),
            environment: ClaudeCommandLine.childEnvironment(
                base: parentEnvironment,
                locations: locations,
                withBrainTools: brainToolServer != nil
            ),
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
        guard await sendControlRequest(to: process, idPrefix: "clicky-model", request: ["subtype": "set_model", "model": model]) != nil else {
            return false
        }
        process.model = model
        return true
    }

    /// Puts the process on the effort this question wants: a stronger one for dig deeper, and back to what the
    /// process started with for the next normal question. A refusal never fails the question; it is answered on
    /// the model alone, and the next question tries again.
    private func settleEffort(of process: ClaudeConversationProcess, to wantedEffort: AnswerEffort?) async -> Bool {
        guard wantedEffort != process.appliedEffort else { return true }
        if !process.hasCapturedStartingEffort {
            // The effort the process started with, read before the first change so it can be put back.
            let settings = await sendControlRequest(to: process, idPrefix: "clicky-settings", request: ["subtype": "get_settings"])
            process.startingEffortLevel = (settings?["effective"] as? [String: Any])?["effortLevel"] as? String
            process.hasCapturedStartingEffort = settings != nil
        }
        // With no effort ever set the CLI reports none; clearing the setting is applying `null`.
        let effortLevel: Any = wantedEffort?.rawValue ?? process.startingEffortLevel ?? NSNull()
        let applied = await sendControlRequest(
            to: process,
            idPrefix: "clicky-effort",
            request: ["subtype": "apply_flag_settings", "settings": ["effortLevel": effortLevel]]
        )
        if applied != nil { process.appliedEffort = wantedEffort }
        return applied != nil
    }

    /// Sends one control request and waits for its answer. Returns the answer's payload (empty when it has none),
    /// or nil when the tool refused, did not answer in time or went away. Other lines are skipped.
    private func sendControlRequest(
        to process: ClaudeConversationProcess,
        idPrefix: String,
        request: [String: Any]
    ) async -> [String: Any]? {
        nextControlRequestNumber += 1
        let requestID = "\(idPrefix)-\(nextControlRequestNumber)"
        let message: [String: Any] = ["type": "control_request", "request_id": requestID, "request": request]
        guard (try? process.send(message)) != nil else { return nil }

        let deadline = Date().addingTimeInterval(Self.modelChangeTimeoutSeconds)
        while true {
            let event = await process.lines.nextEvent(timeoutSeconds: deadline.timeIntervalSinceNow)
            guard case .line(let line) = event else { return nil }
            guard let reply = Self.parse(line), reply["type"] as? String == "control_response",
                  let response = reply["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else {
                continue
            }
            guard response["subtype"] as? String == "success" else { return nil }
            return response["response"] as? [String: Any] ?? [:]
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

    // MARK: Reading one answer

    /// What `readAnswer` hands back once the answer is over.
    private struct FinishedAnswer {
        var text: String
        var secondsToAnswer: Double
        var secondsToFirstText: Double?
        var toolCalls: [BrainToolCall]
        var notesRead: [String]
        var toolResultCharacterCount: Int
        var wasCutShort: Bool
    }

    /// Reads lines until this answer's `result`, reporting progress as text and tool calls arrive. Every turn
    /// prints its own `system`/`init` line, which is where the login kind is checked, so an API-key login is
    /// caught on the first message sent. An answer that keeps printing never times out; only 90 seconds of
    /// silence does.
    private func readAnswer(
        from process: ClaudeConversationProcess,
        running: ClaudeRunningAnswer,
        generation: Int,
        startedAt: ContinuousClock.Instant,
        progress: @Sendable (AnswerProgress) async -> Void
    ) async throws -> FinishedAnswer {
        var accumulator = ClaudeAnswerAccumulator()
        var secondsToFirstText: Double?
        var assistantErrorKind: String?

        func secondsSinceStart() -> Double {
            let elapsed = ContinuousClock.now - startedAt
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        func cutShortAnswer() -> FinishedAnswer {
            FinishedAnswer(
                text: accumulator.text,
                secondsToAnswer: secondsSinceStart(),
                secondsToFirstText: secondsToFirstText,
                toolCalls: accumulator.toolCalls,
                notesRead: accumulator.notesRead,
                toolResultCharacterCount: accumulator.toolResultCharacterCount,
                wasCutShort: true
            )
        }

        while true {
            // After an interrupt the tool has a few seconds to print its `result`, however much it still prints.
            let waitSeconds = running.interruptDeadline.map { max($0.timeIntervalSinceNow, 0) } ?? answerTimeoutSeconds
            let event = await process.lines.nextEvent(timeoutSeconds: waitSeconds)
            switch event {
            case .timedOut:
                await dropProcess(process)
                try refuseWhenConversationMoved(since: generation)
                if running.endedEarly { return cutShortAnswer() }
                throw ProviderFailure.failed(message: "Claude took too long to answer.")
            case .ended:
                await dropProcess(process)
                try refuseWhenConversationMoved(since: generation)
                if running.endedEarly { return cutShortAnswer() }
                throw ProviderFailure.failed(message: "Claude stopped before answering.")
            case .line(let line):
                for streamEvent in ClaudeStreamParser.events(fromLine: line) {
                    switch streamEvent {
                    case .initialized(let keySource):
                        if let keySource, keySource != "none" {
                            await dropProcess(process)
                            throw ProviderFailure.notSubscriptionLogin(
                                detail: "Claude Code is using \(keySource) instead of your Claude subscription."
                            )
                        }
                    case .assistantError(let errorKind):
                        assistantErrorKind = errorKind
                    case .finished(let subtype, let isError, let resultText):
                        let failed = isError || subtype.hasPrefix("error")
                        // An answer ended on purpose prints an error `result`; that is the end, not a failure.
                        if running.endedEarly {
                            var answer = cutShortAnswer()
                            answer.wasCutShort = failed
                            return answer
                        }
                        if failed {
                            throw ClaudeCommandLine.classifyFailure(text: resultText ?? "", assistantErrorKind: assistantErrorKind)
                        }
                        var finalText = accumulator.text
                        if !accumulator.hasReceivedTextDelta {
                            finalText = resultText ?? ""
                            await progress(.textSoFar(finalText))
                        }
                        return FinishedAnswer(
                            text: finalText,
                            secondsToAnswer: secondsSinceStart(),
                            secondsToFirstText: secondsToFirstText,
                            toolCalls: accumulator.toolCalls,
                            notesRead: accumulator.notesRead,
                            toolResultCharacterCount: accumulator.toolResultCharacterCount,
                            wasCutShort: false
                        )
                    default:
                        let reports = accumulator.apply(streamEvent)
                        if secondsToFirstText == nil, accumulator.hasReceivedTextDelta {
                            secondsToFirstText = secondsSinceStart()
                        }
                        for report in reports { await progress(report) }
                        if accumulator.repeatGuardTripped && !running.endedEarly {
                            // The same call a third time in a row: end the answer with what has arrived.
                            running.endedEarly = true
                            sendInterrupt(for: running, to: process)
                        }
                    }
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
