import Foundation

/// Where the question flow is, as the marker and the chat show it.
public enum SessionFlowPhase: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case waitingForAnswer(provider: ProviderID)
}

/// Whether the flow took a key signal or dropped it because an answer is still pending.
public enum SessionSignalOutcome: Equatable, Sendable {
    case accepted
    case ignoredBecauseBusy
}

/// Everything the flow tells the screen. The app implements it and moves the words onto the chat window,
/// the marker and the pointer; the flow itself knows nothing about windows.
public protocol SessionFlowOutput: Sendable {
    func phaseChanged(_ phase: SessionFlowPhase) async
    func questionAsked(_ text: String) async
    /// The answer is complete (or was cut short). `spokenText` has the POINT tag removed. `pointLabel` is nil when
    /// the answer pointed nowhere. `notesRead` are the files the answer drew on (passages sent and tool results).
    func answerReceived(
        spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double, pointLabel: String?,
        notesRead: [String]
    ) async
    /// The visible answer so far, each time it grows: POINT tags removed and a half-written tag hidden.
    func answerTextChanged(visibleText: String, provider: ProviderID, model: String) async
    /// The model began a brain tool call without first saying it was checking: show and say "Checking your notes".
    func checkingNotesShown() async
    func noticeShown(_ text: String) async
    func usageLimitOffered(message: String, switchTo: ProviderID) async
    func usageLimitOfferCleared() async
    func providerChanged(to provider: ProviderID, model: String) async
    /// `globalPoint` is in AppKit global coordinates on the display whose frame is `displayFrameInPoints`.
    func pointerRequested(globalPoint: CGPoint, displayFrameInPoints: CGRect, label: String?) async
}

/// Defaults so an output that does not show streaming yet still compiles; the final answer still arrives.
public extension SessionFlowOutput {
    func answerTextChanged(visibleText: String, provider: ProviderID, model: String) async {}
    func checkingNotesShown() async {}
}

/// The outside world the flow works through: the providers, the microphone's speech, the screen and the log.
public struct SessionQuestionFlowDependencies: Sendable {
    public var makeProvider: @Sendable (ProviderID) -> AnswerProvider
    /// The model setting for a provider, read at each question so a change applies from the next one.
    public var model: @Sendable (ProviderID) async -> String
    public var instructions: String
    public var markQuestionStarted: @Sendable (Date) async -> Void
    public var transcribeQuestion: @Sendable (_ speechFrom: Date, _ speechTo: Date) async throws -> String
    public var captureCurrentGroup: @Sendable () async throws -> ShotGroup
    public var logEvent: @Sendable (SessionEvent) async -> Void
    public var shotsDirectory: URL
    public var timeZone: TimeZone
    public var now: @Sendable () -> Date
    /// The passages from the user's notes for a question, found on the Mac. Always empty while the brain is off.
    public var findPassages: @Sendable (_ question: String, _ frontAppName: String?, _ frontWindowTitle: String?) async -> [BrainPassage]
    /// True when at least one search folder is set at session start (passages and, where supported, the tools).
    public var isBrainOn: Bool
    /// Paths of the maps the instructions name (the knowledge base index, the routing list), read at session start.
    public var brainMapPaths: @Sendable () async -> [String]
    /// The stronger model and effort for a "dig deeper" question; nil keeps the normal model for it.
    public var digDeeperRequest: (@Sendable (ProviderID) async -> AnswerRequest)?

    public init(
        makeProvider: @escaping @Sendable (ProviderID) -> AnswerProvider,
        model: @escaping @Sendable (ProviderID) async -> String,
        instructions: String,
        markQuestionStarted: @escaping @Sendable (Date) async -> Void,
        transcribeQuestion: @escaping @Sendable (Date, Date) async throws -> String,
        captureCurrentGroup: @escaping @Sendable () async throws -> ShotGroup,
        logEvent: @escaping @Sendable (SessionEvent) async -> Void,
        shotsDirectory: URL,
        timeZone: TimeZone,
        now: @escaping @Sendable () -> Date = { Date() },
        findPassages: @escaping @Sendable (String, String?, String?) async -> [BrainPassage] = { _, _, _ in [] },
        isBrainOn: Bool = false,
        brainMapPaths: @escaping @Sendable () async -> [String] = { [] },
        digDeeperRequest: (@Sendable (ProviderID) async -> AnswerRequest)? = nil
    ) {
        self.makeProvider = makeProvider
        self.model = model
        self.instructions = instructions
        self.markQuestionStarted = markQuestionStarted
        self.transcribeQuestion = transcribeQuestion
        self.captureCurrentGroup = captureCurrentGroup
        self.logEvent = logEvent
        self.shotsDirectory = shotsDirectory
        self.timeZone = timeZone
        self.now = now
        self.findPassages = findPassages
        self.isBrainOn = isBrainOn
        self.brainMapPaths = brainMapPaths
        self.digDeeperRequest = digDeeperRequest
    }
}

/// The part of a session that has no windows or hardware in it: question keys in, one provider call per
/// question, answers and log lines out. It is the only writer of the session log, so the order of the log
/// is the order things happened here.
public actor SessionQuestionFlow {
    private let dependencies: SessionQuestionFlowDependencies
    private let output: SessionFlowOutput

    private var activeProviderID: ProviderID
    private var provider: AnswerProvider
    private var phase: SessionFlowPhase = .idle
    private var budget = ConversationBudget()
    private var exchanges: [(question: String, answer: String)] = []
    private var shotGroups: [ShotGroup] = []
    private var allEvents: [SessionEvent] = []
    private var eventsSincePreviousQuestion: [SessionEvent] = []
    private var isFinished = false
    /// True while a provider switch is starting its conversation; keys and second taps on Switch wait it out.
    private var isSwitching = false

    public init(
        initialProvider: ProviderID,
        dependencies: SessionQuestionFlowDependencies,
        output: SessionFlowOutput
    ) {
        self.dependencies = dependencies
        self.output = output
        activeProviderID = initialProvider
        provider = dependencies.makeProvider(initialProvider)
    }

    public var currentProvider: ProviderID { activeProviderID }
    public var answeredQuestionCount: Int { exchanges.count }

    // MARK: Start

    /// Starts the first conversation. Throws the provider's failure, for example when it is not signed in.
    public func begin() async throws {
        let model = await dependencies.model(activeProviderID)
        try await provider.startConversation(instructions: dependencies.instructions, model: model, recap: nil)
    }

    // MARK: Events from the rest of the session

    /// Logs an event (an app switch, a spoken line) and remembers it for the next question's context note.
    public func noteEvent(_ event: SessionEvent) async {
        allEvents.append(event)
        eventsSincePreviousQuestion.append(event)
        await dependencies.logEvent(event)
    }

    /// Remembers a saved screenshot group, so a question about an earlier moment can send it, and logs it.
    public func noteShotGroup(_ group: ShotGroup) async {
        shotGroups.append(group)
        await noteEvent(SessionEvent(time: group.capturedAt, kind: .screenshot(shotGroupID: group.id)))
    }

    // MARK: Question key

    @discardableResult
    public func handle(_ signal: QuestionKeySignal) async -> SessionSignalOutcome {
        guard !isFinished, !isSwitching else { return .ignoredBecauseBusy }
        switch signal {
        case .questionStarted(let date):
            guard phase == .idle else { return .ignoredBecauseBusy }
            await setPhase(.listening)
            await dependencies.markQuestionStarted(date)
            await noteEvent(SessionEvent(time: date, kind: .questionStarted))
            return .accepted
        case .sendQuestion(let speechFrom, let speechTo):
            guard phase == .listening else { return .ignoredBecauseBusy }
            await runQuestion(speechFrom: speechFrom, speechTo: speechTo)
            return .accepted
        }
    }

    private func runQuestion(speechFrom: Date, speechTo: Date) async {
        await setPhase(.transcribing)

        let questionText: String
        do {
            questionText = try await dependencies.transcribeQuestion(speechFrom, speechTo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard !isFinished else { return }
            await output.noticeShown("Could not hear that. Try again.")
            await setPhase(.idle)
            return
        }
        guard !isFinished else { return }
        guard !questionText.isEmpty else {
            await output.noticeShown("Didn't catch that")
            await setPhase(.idle)
            return
        }

        // Questions after the budget is spent begin a fresh conversation that carries a text recap.
        if budget.shouldStartFresh {
            let restartedProvider = provider
            do {
                try await startFreshConversation(provider: restartedProvider, providerID: activeProviderID)
            } catch let failure as ProviderFailure {
                guard !isFinished else { return }
                await output.noticeShown(ProviderFailureNotice.text(for: failure, provider: activeProviderID))
                await setPhase(.idle)
                return
            } catch {
                guard !isFinished else { return }
                await output.noticeShown("The conversation could not be restarted.")
                await setPhase(.idle)
                return
            }
            // Stop landed while the restart was starting: Stop already ended the old conversation, so the
            // one the restart just opened is ended here and the question goes nowhere.
            guard !isFinished else {
                await restartedProvider.endConversation()
                return
            }
        }

        let currentGroup: ShotGroup
        do {
            currentGroup = try await dependencies.captureCurrentGroup()
        } catch {
            guard !isFinished else { return }
            await output.noticeShown("The screen could not be captured.")
            await setPhase(.idle)
            return
        }
        guard !isFinished else { return }

        let now = dependencies.now()
        let earlierGroup = EarlierMomentPicker.pick(
            question: questionText,
            groups: shotGroups.filter { $0.id != currentGroup.id },
            now: now,
            currentAppName: currentGroup.appName,
            currentWindowTitle: currentGroup.windowTitle
        )
        // The note stays in the pending list until an answer comes back, so a retry after a failure carries it.
        let eventsInContextNote = eventsSincePreviousQuestion.count
        let contextNote = ContextNoteBuilder.note(events: eventsSincePreviousQuestion, timeZone: dependencies.timeZone)
        let turn = QuestionTurnBuilder.turn(
            questionText: questionText,
            currentGroup: currentGroup,
            earlierGroup: earlierGroup,
            shotsDirectory: dependencies.shotsDirectory,
            contextNote: contextNote,
            timeZone: dependencies.timeZone
        )

        await noteEvent(SessionEvent(time: now, kind: .question(
            text: questionText,
            shotGroupID: currentGroup.id,
            earlierShotGroupIDs: earlierGroup.map { [$0.id] } ?? []
        )))
        await output.questionAsked(questionText)

        let askedProvider = provider
        let askedProviderID = activeProviderID
        let model = await dependencies.model(askedProviderID)
        // Stop may have landed while the question was being logged and shown; nothing goes to the AI after it.
        guard !isFinished else { return }
        await setPhase(.waitingForAnswer(provider: askedProviderID))

        do {
            let answer = try await askedProvider.ask(turn, model: model)
            guard !isFinished else { return }
            await showAnswer(
                answer, for: turn, group: currentGroup, provider: askedProviderID,
                eventsInContextNote: eventsInContextNote
            )
        } catch let failure as ProviderFailure {
            guard !isFinished else { return }
            await showFailure(failure, provider: askedProviderID, model: model)
        } catch {
            guard !isFinished else { return }
            await showFailure(.failed(message: "The answer could not be fetched."), provider: askedProviderID, model: model)
        }
        guard !isFinished else { return }
        await setPhase(.idle)
    }

    private func showAnswer(
        _ answer: ProviderAnswer, for turn: QuestionTurn, group: ShotGroup, provider providerID: ProviderID,
        eventsInContextNote: Int
    ) async {
        let parsed = PointTagParser.parse(answer.text)
        // An answer with nothing to say once the tag is gone (an unparsed reply, or only [POINT:none]) is a
        // failure, not a blank card, and it is not an exchange: no count, no recap line, no spent note.
        guard !parsed.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await showFailure(
                .failed(message: "No answer came back. Try again."), provider: providerID,
                model: answer.model
            )
            return
        }
        let pointLabel = parsed.label.flatMap { $0 == "none" ? nil : $0 }
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answer(
            text: answer.text, provider: providerID, model: answer.model,
            secondsToAnswer: answer.secondsToAnswer, pointLabel: pointLabel
        )))
        await output.answerReceived(
            spokenText: parsed.spokenText, provider: providerID, model: answer.model,
            secondsToAnswer: answer.secondsToAnswer, pointLabel: pointLabel, notesRead: answer.notesRead
        )
        if let mapped = PointMapper.globalPoint(for: parsed, shots: group.shots) {
            await output.pointerRequested(
                globalPoint: mapped.point, displayFrameInPoints: mapped.shot.displayFrameInPoints, label: pointLabel
            )
        }
        // The note went out with an answer that came back; drop only those events, not ones noted since.
        eventsSincePreviousQuestion.removeFirst(min(eventsInContextNote, eventsSincePreviousQuestion.count))
        budget.recordTurn(imageCount: turn.images.count)
        exchanges.append((question: turn.questionText, answer: answer.text))
    }

    private func showFailure(_ failure: ProviderFailure, provider providerID: ProviderID, model: String) async {
        let notice = ProviderFailureNotice.text(for: failure, provider: providerID)
        var isUsageLimit = false
        if case .usageLimitReached = failure { isUsageLimit = true }
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answerFailed(
            message: notice, provider: providerID, model: model, usageLimitReached: isUsageLimit
        )))
        if isUsageLimit, providerID == .claude {
            await output.usageLimitOffered(message: notice, switchTo: .chatgpt)
        } else {
            await output.noticeShown(notice)
        }
    }

    // MARK: Switching provider

    /// Moves the rest of the session to another provider and gives it a recap of the exchanges so far.
    /// The old conversation ends only after the new one has started.
    public func switchProvider(to newProviderID: ProviderID) async {
        // One switch at a time, and never under a question that is listening, transcribing or waiting.
        guard !isFinished, !isSwitching, phase == .idle, newProviderID != activeProviderID else { return }
        isSwitching = true
        defer { isSwitching = false }
        let oldProvider = provider
        let oldProviderID = activeProviderID
        let newProvider = dependencies.makeProvider(newProviderID)
        let model = await dependencies.model(newProviderID)
        do {
            try await newProvider.startConversation(
                instructions: dependencies.instructions, model: model,
                recap: RecapBuilder.recap(exchanges: exchanges)
            )
        } catch let failure as ProviderFailure {
            guard !isFinished else { return }
            await output.noticeShown(ProviderFailureNotice.text(for: failure, provider: newProviderID))
            return
        } catch {
            guard !isFinished else { return }
            await output.noticeShown("The switch to \(ProviderFailureNotice.displayName(for: newProviderID)) did not work.")
            return
        }
        // Stop landed during the start: Stop already ended the old conversation, so only the new one is left.
        guard !isFinished else {
            await newProvider.endConversation()
            return
        }
        await oldProvider.endConversation()
        provider = newProvider
        activeProviderID = newProviderID
        budget.reset()
        await noteEvent(SessionEvent(
            time: dependencies.now(), kind: .providerSwitched(from: oldProviderID, to: newProviderID)
        ))
        await output.usageLimitOfferCleared()
        await output.providerChanged(to: newProviderID, model: model)
    }

    private func startFreshConversation(provider current: AnswerProvider, providerID: ProviderID) async throws {
        let model = await dependencies.model(providerID)
        await current.endConversation()
        try await current.startConversation(
            instructions: dependencies.instructions, model: model, recap: RecapBuilder.recap(exchanges: exchanges)
        )
        budget.reset()
    }

    // MARK: Stop

    /// Ends the conversation, and with `summaryEnabled` asks for the one text-only summary when at least one
    /// question was answered. A failed summary comes back as nil. Hardware (microphone, screen, key) is already
    /// stopped by the caller. Anything that answers after this is dropped.
    public func finish(summaryEnabled: Bool) async -> String? {
        guard !isFinished else { return nil }
        isFinished = true
        phase = .idle
        let stoppedEvent = SessionEvent(time: dependencies.now(), kind: .sessionStopped)
        allEvents.append(stoppedEvent)
        await dependencies.logEvent(stoppedEvent)

        var summary: String?
        if summaryEnabled, !exchanges.isEmpty {
            let model = await dependencies.model(activeProviderID)
            let text = SessionSummaryInput.text(events: allEvents, timeZone: dependencies.timeZone)
            if let written = try? await provider.summarize(text, instructions: SessionSummaryInput.instructions, model: model) {
                let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
                summary = trimmed.isEmpty ? nil : trimmed
            }
        }
        await provider.endConversation()
        return summary
    }

    // MARK: Phase

    private func setPhase(_ newPhase: SessionFlowPhase) async {
        phase = newPhase
        await output.phaseChanged(newPhase)
    }
}
