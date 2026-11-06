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
    /// A newer question ended this answer while it was still coming. `visibleText` is what had arrived; the app
    /// finishes the chat message as cut short and shows nothing else for it.
    func answerCutShort(visibleText: String, provider: ProviderID, model: String, notesRead: [String]) async
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
    func answerCutShort(visibleText: String, provider: ProviderID, model: String, notesRead: [String]) async {}
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
    /// True from the moment Stop begins until the session is finished, while it waits for a running answer to end.
    private var isStopping = false
    /// Counts the questions that began listening while an answer was still coming. Work for a question whose
    /// number is no longer the current one was ended by a newer question or by Stop, and shows nothing.
    private var questionSerial = 0
    /// Questions whose provider call is still running, so Stop can wait for a cut answer to reach the log.
    private var answersInFlight: Set<Int> = []
    /// The words of the question asked before the current one; "dig deeper" searches with them.
    private var previousQuestionText: String?
    /// What the current answer has shown so far; nil between answers.
    private var streamingAnswer: StreamingAnswerState?

    /// The per-answer facts the progress reports build up.
    private struct StreamingAnswerState {
        var group: ShotGroup
        var provider: ProviderID
        var model: String
        var visibleText = ""
        var checkingNotesRule = CheckingNotesRule()
        var hasFlownPointer = false
    }

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
        try await provider.startConversation(
            instructions: await conversationInstructions(for: provider), model: model, recap: nil
        )
    }

    /// Today's instructions with the brain off. With it on, the notes rules for what this provider can do:
    /// passages and the two tools, or passages only.
    private func conversationInstructions(for candidate: AnswerProvider) async -> String {
        guard dependencies.isBrainOn else { return dependencies.instructions }
        let brainAccess: AnswerInstructions.BrainAccess = candidate.supportsBrainTools
            ? .passagesAndTools(mapPaths: await dependencies.brainMapPaths())
            : .passagesOnly
        return AnswerInstructions.questionInstructions(brainAccess: brainAccess)
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
        guard !isFinished, !isStopping, !isSwitching else { return .ignoredBecauseBusy }
        switch signal {
        case .questionStarted(let date):
            switch phase {
            case .idle:
                await setPhase(.listening)
            case .waitingForAnswer:
                // A new question ends the answer still coming. The number moves on first, so everything the old
                // answer reports from here on is dropped; the phase moves on before the first await, so a second
                // tap sees a busy flow.
                questionSerial += 1
                phase = .listening
                await provider.stopCurrentAnswer()
                guard !isFinished else { return .ignoredBecauseBusy }
                await output.phaseChanged(.listening)
            case .listening, .transcribing:
                return .ignoredBecauseBusy
            }
            await dependencies.markQuestionStarted(date)
            await noteEvent(SessionEvent(time: date, kind: .questionStarted))
            return .accepted
        case .sendQuestion(let speechFrom, let speechTo):
            guard phase == .listening else { return .ignoredBecauseBusy }
            await runQuestion(speechFrom: speechFrom, speechTo: speechTo, serial: questionSerial)
            return .accepted
        }
    }

    /// False once Stop landed or a newer question took over from the question with this number.
    private func isCurrent(_ serial: Int) -> Bool {
        !isFinished && serial == questionSerial
    }

    private func runQuestion(speechFrom: Date, speechTo: Date, serial: Int) async {
        await setPhase(.transcribing)

        let questionText: String
        do {
            questionText = try await dependencies.transcribeQuestion(speechFrom, speechTo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard isCurrent(serial) else { return }
            await output.noticeShown("Could not hear that. Try again.")
            await setPhase(.idle)
            return
        }
        guard isCurrent(serial) else { return }
        guard !questionText.isEmpty else {
            await output.noticeShown("Didn't catch that")
            await setPhase(.idle)
            return
        }

        // Only spoken words ask for a deeper look, and only when a stronger setup is configured.
        let digDeeperMatch = dependencies.digDeeperRequest == nil ? nil : DigDeeperMatcher.match(questionText)

        // Questions after the budget is spent begin a fresh conversation that carries a text recap.
        if budget.shouldStartFresh {
            let restartedProvider = provider
            do {
                try await startFreshConversation(provider: restartedProvider, providerID: activeProviderID)
            } catch let failure as ProviderFailure {
                guard isCurrent(serial) else { return }
                await output.noticeShown(ProviderFailureNotice.text(for: failure, provider: activeProviderID))
                await setPhase(.idle)
                return
            } catch {
                guard isCurrent(serial) else { return }
                await output.noticeShown("The conversation could not be restarted.")
                await setPhase(.idle)
                return
            }
            // Stop landed while the restart was starting: Stop already ended the old conversation, so the
            // one the restart just opened is ended here and the question goes nowhere.
            guard isCurrent(serial) else {
                await restartedProvider.endConversation()
                return
            }
        }

        let currentGroup: ShotGroup
        do {
            currentGroup = try await dependencies.captureCurrentGroup()
        } catch {
            guard isCurrent(serial) else { return }
            await output.noticeShown("The screen could not be captured.")
            await setPhase(.idle)
            return
        }
        guard isCurrent(serial) else { return }

        // The passages come from the Mac after the capture, so the front app and window can steer the search.
        // "Dig deeper" searches with the question before it plus the words that followed the phrase.
        var passages: [BrainPassage] = []
        if dependencies.isBrainOn {
            let passageQuery: String
            if let digDeeperMatch {
                passageQuery = [previousQuestionText, digDeeperMatch.remainingWords]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                passageQuery = questionText
            }
            if !passageQuery.isEmpty {
                passages = await dependencies.findPassages(passageQuery, currentGroup.appName, currentGroup.windowTitle)
            }
            guard isCurrent(serial) else { return }
        }

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
        var turn = QuestionTurnBuilder.turn(
            questionText: questionText,
            currentGroup: currentGroup,
            earlierGroup: earlierGroup,
            shotsDirectory: dependencies.shotsDirectory,
            contextNote: contextNote,
            timeZone: dependencies.timeZone
        )
        turn.brainNote = BrainPassageNote.text(for: passages)

        let askedProvider = provider
        let askedProviderID = activeProviderID
        let request: AnswerRequest
        if digDeeperMatch != nil, let digDeeperRequest = dependencies.digDeeperRequest {
            request = await digDeeperRequest(askedProviderID)
        } else {
            request = AnswerRequest(model: await dependencies.model(askedProviderID), effort: nil)
        }
        guard isCurrent(serial) else { return }

        if digDeeperMatch != nil {
            await noteEvent(SessionEvent(time: now, kind: .digDeeperAsked(
                model: request.model, effort: request.effort?.rawValue
            )))
        }
        await noteEvent(SessionEvent(time: now, kind: .question(
            text: questionText,
            shotGroupID: currentGroup.id,
            earlierShotGroupIDs: earlierGroup.map { [$0.id] } ?? []
        )))
        var passagePaths: [String] = []
        for passage in passages where !passagePaths.contains(passage.path) { passagePaths.append(passage.path) }
        if !passagePaths.isEmpty {
            await noteEvent(SessionEvent(time: now, kind: .passagesAttached(paths: passagePaths)))
        }
        previousQuestionText = questionText
        await output.questionAsked(questionText)

        // Stop may have landed while the question was being logged and shown; nothing goes to the AI after it.
        guard isCurrent(serial) else { return }
        await setPhase(.waitingForAnswer(provider: askedProviderID))
        guard isCurrent(serial) else { return }

        streamingAnswer = StreamingAnswerState(group: currentGroup, provider: askedProviderID, model: request.model)
        answersInFlight.insert(serial)
        defer { answersInFlight.remove(serial) }

        do {
            let answer = try await askedProvider.answer(turn, request: request) { [self] progress in
                await receiveProgress(progress, serial: serial)
            }
            let notesRead = Self.withoutRepeats(passagePaths + answer.notesRead)
            guard serial == questionSerial else {
                // A newer question or Stop ended this answer. What had arrived goes to the log (and, for a newer
                // question, to the chat); nothing else is touched.
                guard !isFinished else { return }
                await logCutShortAnswer(answer, provider: askedProviderID, notesRead: notesRead)
                return
            }
            guard !isFinished else { return }
            let hasStreamedPointer = streamingAnswer?.hasFlownPointer ?? false
            streamingAnswer = nil
            await showAnswer(
                answer, for: turn, group: currentGroup, provider: askedProviderID,
                eventsInContextNote: eventsInContextNote, notesRead: notesRead,
                hasStreamedPointer: hasStreamedPointer
            )
        } catch let failure as ProviderFailure {
            guard !isFinished else { return }
            await showFailure(
                failure, provider: askedProviderID, model: request.model, showsNotice: serial == questionSerial
            )
        } catch {
            guard !isFinished else { return }
            await showFailure(
                .failed(message: "The answer could not be fetched."), provider: askedProviderID, model: request.model,
                showsNotice: serial == questionSerial
            )
        }
        // A superseded question leaves the phase to the newer one.
        guard isCurrent(serial) else { return }
        streamingAnswer = nil
        await setPhase(.idle)
    }

    private static func withoutRepeats(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: Streaming

    /// A report from the provider while the answer is coming. Reports of an answer that a newer question or
    /// Stop ended are dropped.
    private func receiveProgress(_ progress: AnswerProgress, serial: Int) async {
        guard isCurrent(serial), var state = streamingAnswer else { return }
        switch progress {
        case .textSoFar(let rawTextSoFar):
            let view = StreamingAnswerText.visible(rawTextSoFar: rawTextSoFar)
            let visibleTextChanged = view.visibleText != state.visibleText
            if visibleTextChanged {
                state.visibleText = view.visibleText
                state.checkingNotesRule.textChanged(visibleTextSoFar: view.visibleText)
            }
            // The pointer flies once, at the first complete tag that lands on a screen, current screens only.
            var pointerToFly: (point: CGPoint, frame: CGRect, label: String?)?
            if !state.hasFlownPointer, let tag = view.firstCompletePoint,
               let mapped = PointMapper.globalPoint(for: tag, shots: state.group.shots) {
                state.hasFlownPointer = true
                pointerToFly = (mapped.point, mapped.shot.displayFrameInPoints, tag.label.flatMap { $0 == "none" ? nil : $0 })
            }
            streamingAnswer = state
            if visibleTextChanged {
                await output.answerTextChanged(visibleText: view.visibleText, provider: state.provider, model: state.model)
            }
            if let pointerToFly, isCurrent(serial) {
                await output.pointerRequested(
                    globalPoint: pointerToFly.point, displayFrameInPoints: pointerToFly.frame, label: pointerToFly.label
                )
            }
        case .toolCallStarted:
            let shouldShowLine = state.checkingNotesRule.toolCallStarted(visibleTextSoFar: state.visibleText)
            streamingAnswer = state
            if shouldShowLine { await output.checkingNotesShown() }
        case .toolCallMade(let call):
            await noteEvent(SessionEvent(time: dependencies.now(), kind: .brainToolCalled(
                tool: call.tool.rawValue, argument: call.argument
            )))
        case .toolCallFinished:
            break
        }
    }

    /// Logs an answer a newer question or Stop ended early. The chat hears about it only for a newer question;
    /// after Stop the cut answer is in the log and nowhere else.
    private func logCutShortAnswer(_ answer: ProviderAnswer, provider providerID: ProviderID, notesRead: [String]) async {
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answerTiming(
            secondsToFirstText: answer.secondsToFirstText, toolCallCount: answer.toolCalls.count, wasCutShort: true
        )))
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answer(
            text: answer.text, provider: providerID, model: answer.model,
            secondsToAnswer: answer.secondsToAnswer, pointLabel: nil
        )))
        guard !isStopping, !isFinished else { return }
        await output.answerCutShort(
            visibleText: StreamingAnswerText.visible(rawTextSoFar: answer.text).visibleText,
            provider: providerID, model: answer.model, notesRead: notesRead
        )
    }

    private func showAnswer(
        _ answer: ProviderAnswer, for turn: QuestionTurn, group: ShotGroup, provider providerID: ProviderID,
        eventsInContextNote: Int, notesRead: [String], hasStreamedPointer: Bool
    ) async {
        let parsed = PointTagParser.parse(answer.text)
        // An answer with nothing to say once the tag is gone (an unparsed reply, or only [POINT:none]) is a
        // failure, not a blank card, and it is not an exchange: no count, no recap line, no spent note.
        guard !parsed.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await showFailure(
                .failed(message: "No answer came back. Try again."), provider: providerID,
                model: answer.model, showsNotice: true
            )
            return
        }
        let pointLabel = parsed.label.flatMap { $0 == "none" ? nil : $0 }
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answerTiming(
            secondsToFirstText: answer.secondsToFirstText, toolCallCount: answer.toolCalls.count,
            wasCutShort: answer.wasCutShort
        )))
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answer(
            text: answer.text, provider: providerID, model: answer.model,
            secondsToAnswer: answer.secondsToAnswer, pointLabel: pointLabel
        )))
        await output.answerReceived(
            spokenText: parsed.spokenText, provider: providerID, model: answer.model,
            secondsToAnswer: answer.secondsToAnswer, pointLabel: pointLabel, notesRead: notesRead
        )
        if !hasStreamedPointer, let mapped = PointMapper.globalPoint(for: parsed, shots: group.shots) {
            await output.pointerRequested(
                globalPoint: mapped.point, displayFrameInPoints: mapped.shot.displayFrameInPoints, label: pointLabel
            )
        }
        // The note went out with an answer that came back; drop only those events, not ones noted since.
        eventsSincePreviousQuestion.removeFirst(min(eventsInContextNote, eventsSincePreviousQuestion.count))
        budget.recordTurn(
            imageCount: turn.images.count,
            attachedCharacterCount: turn.brainNote.count + answer.toolResultCharacterCount
        )
        exchanges.append((question: turn.questionText, answer: answer.text))
    }

    /// Logs a failed answer. `showsNotice` is false for a question a newer question or Stop already replaced.
    private func showFailure(
        _ failure: ProviderFailure, provider providerID: ProviderID, model: String, showsNotice: Bool
    ) async {
        let notice = ProviderFailureNotice.text(for: failure, provider: providerID)
        var isUsageLimit = false
        if case .usageLimitReached = failure { isUsageLimit = true }
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answerFailed(
            message: notice, provider: providerID, model: model, usageLimitReached: isUsageLimit
        )))
        guard showsNotice else { return }
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
                instructions: await conversationInstructions(for: newProvider), model: model,
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
            instructions: await conversationInstructions(for: current), model: model,
            recap: RecapBuilder.recap(exchanges: exchanges)
        )
        budget.reset()
    }

    // MARK: Stop

    /// Ends the conversation, and with `summaryEnabled` asks for the one text-only summary when at least one
    /// question was answered. A failed summary comes back as nil. Hardware (microphone, screen, key) is already
    /// stopped by the caller. Anything that answers after this is dropped.
    public func finish(summaryEnabled: Bool) async -> String? {
        guard !isFinished, !isStopping else { return nil }
        isStopping = true
        if case .waitingForAnswer = phase {
            // End the answer still coming so the drain does not wait on a long search. What had arrived goes to
            // the log before the stop line; it is never shown.
            questionSerial += 1
            await provider.stopCurrentAnswer()
            await waitForEndedAnswersToBeLogged()
        }
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

    /// Waits (at most two seconds) until the provider calls that Stop ended have returned and logged.
    private func waitForEndedAnswersToBeLogged() async {
        for _ in 0..<400 where !answersInFlight.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Phase

    private func setPhase(_ newPhase: SessionFlowPhase) async {
        phase = newPhase
        await output.phaseChanged(newPhase)
    }
}
