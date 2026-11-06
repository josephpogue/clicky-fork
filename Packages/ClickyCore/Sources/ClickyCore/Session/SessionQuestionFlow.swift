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

/// Why an answer ended before it was complete; the chat's last line for that answer says it.
public enum AnswerCutReason: Sendable, Equatable {
    /// A newer question ended it: "(Cut short by your next question.)"
    case newerQuestion
    /// The provider failed or stopped partway: "(Cut short.)"; the failure's notice shows separately.
    case failed
    /// Stop or quit ended it: "(Stopped.)"
    case stopped
    /// A newer question asked to end it, but the whole answer had already arrived: the card shows it complete, no line.
    case completedAfterNewerQuestion
}

/// Everything the flow tells the screen. The app implements it and moves the words onto the chat window,
/// the marker and the pointer; the flow itself knows nothing about windows.
///
/// The contract for answer reports (the app relies on it). Every question has its own `answerNumber`, given first by
/// `questionAsked`. For each number the flow sends exactly one `answerReceived` or exactly one `answerCutShort`, or
/// nothing (an answer Stop ended, or a question that never reached the provider). Every report for an answer a newer
/// question already ended is nothing or that one `answerCutShort`, so a late report of an ended answer is never a
/// second card. After a newer question or Stop ended an answer, no `answerReceived`, notice, usage-limit offer or
/// pointer goes out for it. Once Stop begins nothing is reported at all.
public protocol SessionFlowOutput: Sendable {
    func phaseChanged(_ phase: SessionFlowPhase) async
    /// `answerNumber` names this question's answer in every later answer report (text, checking line, tool call,
    /// final answer, cut short), so the app can tell the current answer's reports from an ended one's.
    func questionAsked(_ text: String, answerNumber: Int) async
    /// The answer is complete (or was cut short). `spokenText` has the POINT tag removed. `pointLabel` is nil when
    /// the answer pointed nowhere. `notesRead` are the files the answer drew on (passages sent and tool results).
    func answerReceived(
        answerNumber: Int, spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double,
        pointLabel: String?, notesRead: [String]
    ) async
    /// The visible answer so far, each time it grows: POINT tags removed and a half-written tag hidden.
    func answerTextChanged(answerNumber: Int, visibleText: String, provider: ProviderID, model: String) async
    /// The model began a brain tool call without first saying it was checking: show and say "Checking your notes".
    func checkingNotesShown(answerNumber: Int) async
    /// An answer ended before it was complete. `visibleText` is what had arrived; the app finishes the chat message
    /// with the line for `reason` and shows nothing else for it (a failure's notice arrives on its own).
    /// `answerNumber` is the number `questionAsked` gave this answer. Never sent after Stop began.
    func answerCutShort(
        answerNumber: Int, visibleText: String, provider: ProviderID, model: String, notesRead: [String],
        reason: AnswerCutReason
    ) async
    /// The model began a tool call (every one, whether or not the checking line shows): a sentence that ended right
    /// before it is complete even with no space after it yet, so speech may say it now.
    func toolCallStarted(answerNumber: Int) async
    func noticeShown(_ text: String) async
    func usageLimitOffered(message: String, switchTo: ProviderID) async
    func usageLimitOfferCleared() async
    func providerChanged(to provider: ProviderID, model: String) async
    /// `globalPoint` is in AppKit global coordinates on the display whose frame is `displayFrameInPoints`.
    func pointerRequested(globalPoint: CGPoint, displayFrameInPoints: CGRect, label: String?) async
}

/// Defaults so an output that does not show streaming yet still compiles; the final answer still arrives.
public extension SessionFlowOutput {
    func answerTextChanged(answerNumber: Int, visibleText: String, provider: ProviderID, model: String) async {}
    func checkingNotesShown(answerNumber: Int) async {}
    func answerCutShort(
        answerNumber: Int, visibleText: String, provider: ProviderID, model: String, notesRead: [String],
        reason: AnswerCutReason
    ) async {}
    func toolCallStarted(answerNumber: Int) async {}
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
    /// What each running answer has shown so far, by question number; an entry leaves when its question ends. Keyed by
    /// number so an ended answer's failure reports its own streamed text, never a newer answer's.
    private var streamingAnswers: [Int: StreamingAnswerState] = [:]
    /// The provider's stop of the answer a new question ended, running off the listening path. The new question waits
    /// for it before it is transcribed, so the old answer is in the log first.
    private var pendingAnswerStop: Task<Void, Never>?

    /// The per-answer facts the progress reports build up.
    private struct StreamingAnswerState {
        var group: ShotGroup
        var provider: ProviderID
        var model: String
        var visibleText = ""
        var checkingNotesRule = CheckingNotesRule()
        var hasFlownPointer = false
        /// The tag the pointer flew to while streaming, so a later tag in the final text can be told apart.
        var flownTag: PointTagParseResult?
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
                // Every question has its own number, also one asked with nothing running.
                questionSerial += 1
                await setPhase(.listening)
            case .waitingForAnswer:
                // A new question ends the answer still coming. The number moves on first, so everything the old
                // answer reports from here on is dropped; the phase moves on before the first await, so a second
                // tap sees a busy flow. Listening shows at once, like a question with nothing running; the old
                // answer is stopped off this path (see `stopEndedAnswerOffTheListeningPath`).
                questionSerial += 1
                phase = .listening
                // The stop starts before the first await, so a send that arrives during any of them waits for it.
                stopEndedAnswerOffTheListeningPath()
                await output.phaseChanged(.listening)
                guard !isFinished else { return .ignoredBecauseBusy }
                await dependencies.markQuestionStarted(date)
                await noteEvent(SessionEvent(time: date, kind: .questionStarted))
                return .accepted
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

    /// Stops the answer a new question ended without holding the new question's listening back: the provider may take
    /// up to its grace period to hand the answer back. The question's send waits for this task.
    private func stopEndedAnswerOffTheListeningPath() {
        let stoppingProvider = provider
        pendingAnswerStop = Task { [self] in
            await stoppingProvider.stopCurrentAnswer()
            await waitForEndedAnswersToBeLogged()
        }
    }

    /// False once Stop landed or a newer question took over from the question with this number.
    private func isCurrent(_ serial: Int) -> Bool {
        !isFinished && serial == questionSerial
    }

    private func runQuestion(speechFrom: Date, speechTo: Date, serial: Int) async {
        await setPhase(.transcribing)
        // The old answer a new question ended is stopped and logged before this question is transcribed.
        if let stopOfOldAnswer = pendingAnswerStop {
            await stopOfOldAnswer.value
            pendingAnswerStop = nil
            guard isCurrent(serial) else { return }
        }

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

        // Only spoken words ask for a deeper look, and only when a stronger setup is configured and the brain is on:
        // with no search folders Clicky behaves exactly as it did before the brain existed.
        let digDeeperMatch = (dependencies.isBrainOn && dependencies.digDeeperRequest != nil)
            ? DigDeeperMatcher.match(questionText) : nil

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
        // A "dig deeper" question is not itself the earlier question the next "dig deeper" should search with.
        if digDeeperMatch == nil { previousQuestionText = questionText }
        await output.questionAsked(questionText, answerNumber: serial)

        // Stop may have landed while the question was being logged and shown; nothing goes to the AI after it.
        guard isCurrent(serial) else {
            await reportEndedBeforeAnswering(serial: serial, provider: askedProviderID, model: request.model, notesRead: passagePaths)
            return
        }
        // The phase, the in-flight mark and the streamed state are in place before the phase report is awaited: a new
        // question tapped during that await is accepted, and this answer must already be known to it and to Stop.
        phase = .waitingForAnswer(provider: askedProviderID)
        streamingAnswers[serial] = StreamingAnswerState(group: currentGroup, provider: askedProviderID, model: request.model)
        answersInFlight.insert(serial)
        defer {
            answersInFlight.remove(serial)
            streamingAnswers[serial] = nil
        }
        await output.phaseChanged(.waitingForAnswer(provider: askedProviderID))
        guard isCurrent(serial) else {
            await reportEndedBeforeAnswering(serial: serial, provider: askedProviderID, model: request.model, notesRead: passagePaths)
            return
        }

        // The dig deeper line is written once the provider has answered, because only then is it known whether the
        // stronger effort was really applied.
        func noteDigDeeperAsked(for answer: ProviderAnswer?) async {
            guard digDeeperMatch != nil else { return }
            let effortName = answer?.effortWasApplied == false ? nil : request.effort?.rawValue
            await noteEvent(SessionEvent(time: dependencies.now(), kind: .digDeeperAsked(
                model: request.model, effort: effortName
            )))
        }

        do {
            let answer = try await askedProvider.answer(turn, request: request) { [self] progress in
                await receiveProgress(progress, serial: serial)
            }
            let notesRead = Self.withoutRepeats(passagePaths + answer.notesRead)
            guard serial == questionSerial else {
                // A newer question or Stop ended this answer. What had arrived goes to the log (and, for a newer
                // question, to the chat); nothing else is touched.
                guard !isFinished else { return }
                await noteDigDeeperAsked(for: answer)
                await logEndedAnswer(answer, for: turn, provider: askedProviderID, notesRead: notesRead, serial: serial)
                return
            }
            guard !isFinished else { return }
            let streamedState = streamingAnswers[serial]
            streamingAnswers[serial] = nil
            await noteDigDeeperAsked(for: answer)
            await showAnswer(
                answer, for: turn, group: currentGroup, provider: askedProviderID,
                eventsInContextNote: eventsInContextNote, notesRead: notesRead,
                streamedState: streamedState, serial: serial
            )
        } catch let failure as ProviderFailure {
            guard !isFinished else { return }
            await noteDigDeeperAsked(for: nil)
            await showFailure(
                failure, provider: askedProviderID, model: request.model,
                notesRead: passagePaths, serial: serial
            )
        } catch {
            guard !isFinished else { return }
            await noteDigDeeperAsked(for: nil)
            await showFailure(
                .failed(message: "The answer could not be fetched."), provider: askedProviderID, model: request.model,
                notesRead: passagePaths, serial: serial
            )
        }
        // A superseded question leaves the phase to the newer one.
        guard isCurrent(serial) else { return }
        await setPhase(.idle)
    }

    /// The one ended report of a question that was shown but never reached the provider because a newer question took
    /// over. After Stop began nothing is sent.
    private func reportEndedBeforeAnswering(serial: Int, provider providerID: ProviderID, model: String, notesRead: [String]) async {
        guard !isFinished, !isStopping else { return }
        await output.answerCutShort(
            answerNumber: serial, visibleText: "", provider: providerID, model: model, notesRead: notesRead,
            reason: .newerQuestion
        )
    }

    private static func withoutRepeats(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: Streaming

    /// A report from the provider while the answer is coming. Reports of an answer that a newer question or
    /// Stop ended are dropped.
    private func receiveProgress(_ progress: AnswerProgress, serial: Int) async {
        guard isCurrent(serial), var state = streamingAnswers[serial] else { return }
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
                state.flownTag = tag
                pointerToFly = (mapped.point, mapped.shot.displayFrameInPoints, tag.label.flatMap { $0 == "none" ? nil : $0 })
            }
            streamingAnswers[serial] = state
            if visibleTextChanged {
                await output.answerTextChanged(answerNumber: serial, visibleText: view.visibleText, provider: state.provider, model: state.model)
            }
            if let pointerToFly, isCurrent(serial) {
                await output.pointerRequested(
                    globalPoint: pointerToFly.point, displayFrameInPoints: pointerToFly.frame, label: pointerToFly.label
                )
            }
        case .toolCallStarted:
            let shouldShowLine = state.checkingNotesRule.toolCallStarted(visibleTextSoFar: state.visibleText)
            streamingAnswers[serial] = state
            await output.toolCallStarted(answerNumber: serial)
            if shouldShowLine, isCurrent(serial) { await output.checkingNotesShown(answerNumber: serial) }
        case .toolCallMade(let call):
            await noteEvent(SessionEvent(time: dependencies.now(), kind: .brainToolCalled(
                tool: call.tool.rawValue, argument: call.argument
            )))
        case .toolCallFinished:
            break
        }
    }

    /// Logs an answer a newer question or Stop ended. The chat hears about it only for a newer question and only when
    /// the answer really was cut; after Stop the answer is in the log and nowhere else. An answer that completed
    /// anyway (the stop landed after its final text) is logged as complete and not shown again.
    private func logEndedAnswer(
        _ answer: ProviderAnswer, for turn: QuestionTurn, provider providerID: ProviderID, notesRead: [String],
        serial: Int
    ) async {
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answerTiming(
            secondsToFirstText: answer.secondsToFirstText, toolCallCount: answer.toolCalls.count,
            wasCutShort: answer.wasCutShort
        )))
        let completedLabel = answer.wasCutShort ? nil : PointTagParser.parse(answer.text).label.flatMap { $0 == "none" ? nil : $0 }
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answer(
            text: answer.text, provider: providerID, model: answer.model,
            secondsToAnswer: answer.secondsToAnswer, pointLabel: completedLabel
        )))
        // The images, passages and tool results of a cut answer stayed in the conversation, so they count.
        recordTurnInBudget(turn, answer: answer)
        // Every answer a newer question ended reports once, even one that completed after the stop, so the app's
        // pairing of reports to retired answers stays in step.
        guard !isStopping, !isFinished else { return }
        await output.answerCutShort(
            answerNumber: serial,
            visibleText: StreamingAnswerText.visible(rawTextSoFar: answer.text).visibleText,
            provider: providerID, model: answer.model, notesRead: notesRead,
            reason: answer.wasCutShort ? .newerQuestion : .completedAfterNewerQuestion
        )
    }

    private func recordTurnInBudget(_ turn: QuestionTurn, answer: ProviderAnswer) {
        budget.recordTurn(
            imageCount: turn.images.count,
            attachedCharacterCount: turn.brainNote.count + answer.toolResultCharacterCount
        )
    }

    private func showAnswer(
        _ answer: ProviderAnswer, for turn: QuestionTurn, group: ShotGroup, provider providerID: ProviderID,
        eventsInContextNote: Int, notesRead: [String], streamedState: StreamingAnswerState?, serial: Int
    ) async {
        let parsed = PointTagParser.parse(answer.text)
        // An answer with nothing to say once the tag is gone (an unparsed reply, or only [POINT:none]) is a
        // failure, not a blank card, and it is not an exchange: no count, no recap line, no spent note.
        guard !parsed.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await showFailure(
                .failed(message: "No answer came back. Try again."), provider: providerID,
                model: answer.model, notesRead: notesRead, serial: serial
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
        // The log writes above were awaited, so a newer question or Stop may have taken over since the caller's check.
        // The answer is then ended: its one report says so, and the screen, voice and pointer get nothing from it.
        guard isCurrent(serial) else {
            recordTurnInBudget(turn, answer: answer)
            guard !isFinished, !isStopping else { return }
            await output.answerCutShort(
                answerNumber: serial,
                visibleText: StreamingAnswerText.visible(rawTextSoFar: answer.text).visibleText,
                provider: providerID, model: answer.model, notesRead: notesRead,
                reason: answer.wasCutShort ? .newerQuestion : .completedAfterNewerQuestion
            )
            return
        }
        if answer.wasCutShort {
            // The provider ended this answer on its own (the repeat guard) while it was still the current question:
            // it is not a complete answer, so the chat finishes the message as cut short instead of receiving it.
            await output.answerCutShort(
                answerNumber: serial,
                visibleText: StreamingAnswerText.visible(rawTextSoFar: answer.text).visibleText,
                provider: providerID, model: answer.model, notesRead: notesRead, reason: .failed
            )
        } else {
            await output.answerReceived(
                answerNumber: serial, spokenText: parsed.spokenText, provider: providerID, model: answer.model,
                secondsToAnswer: answer.secondsToAnswer, pointLabel: pointLabel, notesRead: notesRead
            )
            // A newer question may have begun while the answer was logged and shown; its pointer must not be moved.
            // The pointer flies now when it did not fly while streaming, or when the final tag (a correction later in
            // the text) points somewhere other than the spot it already flew to.
            if isCurrent(serial), let mapped = PointMapper.globalPoint(for: parsed, shots: group.shots),
               streamedState?.flownTag.map({ Self.pointsElsewhere(parsed, than: $0) }) ?? true {
                await output.pointerRequested(
                    globalPoint: mapped.point, displayFrameInPoints: mapped.shot.displayFrameInPoints, label: pointLabel
                )
            }
        }
        // The note went out with an answer that came back; drop only those events, not ones noted since.
        eventsSincePreviousQuestion.removeFirst(min(eventsInContextNote, eventsSincePreviousQuestion.count))
        recordTurnInBudget(turn, answer: answer)
        exchanges.append((question: turn.questionText, answer: answer.text))
    }

    /// True when the final tag names another spot than the tag the pointer already flew to.
    private static func pointsElsewhere(_ finalTag: PointTagParseResult, than flownTag: PointTagParseResult) -> Bool {
        finalTag.coordinate != flownTag.coordinate || finalTag.screenNumber != flownTag.screenNumber
    }

    /// Logs a failed answer. Whether the answer is still the current one is decided after the log write, because a new
    /// question can land during it; an ended answer shows no notice or offer, only its one ended report. When the
    /// current answer had already shown text, its chat message is finished as cut short before the notice.
    private func showFailure(
        _ failure: ProviderFailure, provider providerID: ProviderID, model: String,
        notesRead: [String] = [], serial: Int
    ) async {
        let notice = ProviderFailureNotice.text(for: failure, provider: providerID)
        var isUsageLimit = false
        if case .usageLimitReached = failure { isUsageLimit = true }
        await noteEvent(SessionEvent(time: dependencies.now(), kind: .answerFailed(
            message: notice, provider: providerID, model: model, usageLimitReached: isUsageLimit
        )))
        let streamedText = streamingAnswers[serial]?.visibleText ?? ""
        guard isCurrent(serial) else {
            // A newer question (or Stop) replaced this answer: no notice, but the one ended report still goes out so
            // the app's pairing of reports to retired answers stays in step.
            if !isStopping, !isFinished {
                await output.answerCutShort(
                    answerNumber: serial, visibleText: streamedText, provider: providerID, model: model,
                    notesRead: notesRead, reason: .newerQuestion
                )
            }
            return
        }
        if !streamedText.isEmpty {
            streamingAnswers[serial] = nil
            await output.answerCutShort(
                answerNumber: serial,
                visibleText: streamedText, provider: providerID, model: model, notesRead: notesRead, reason: .failed
            )
            // The cut report took an await: a newer question may have landed in it, and then its notice would
            // appear over that question's listening.
            guard isCurrent(serial) else { return }
        }
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
        // Any answer still in flight is ended, whatever the phase: a new question may be listening or transcribing
        // while the answer it ended is still being interrupted. What had arrived goes to the log before the stop
        // line; it is never shown.
        var isAnswerComing = !answersInFlight.isEmpty || pendingAnswerStop != nil
        if case .waitingForAnswer = phase { isAnswerComing = true }
        if isAnswerComing {
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
