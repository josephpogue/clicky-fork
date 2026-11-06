import Foundation
@testable import ClickyCore

/// Holds a caller at a point until the test opens it, so a test can press Stop at an exact moment.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrived = false
    private var waiting: CheckedContinuation<Void, Never>?

    /// True once a caller has reached the gate.
    var hasArrived: Bool { lock.lock(); defer { lock.unlock() }; return arrived }

    func pass() async {
        lock.lock(); arrived = true; lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume()
    }

    /// Waits (up to two seconds) until a caller is held at the gate.
    func waitUntilReached() async {
        for _ in 0..<200 where !hasArrived { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

/// A test double of the AnswerProvider contract (the real ones run the claude and codex tools).
/// It records every call and answers from a script, so the flow's own logic is what the tests exercise.
final class FakeAnswerProvider: AnswerProvider, @unchecked Sendable {
    struct StartCall: Equatable {
        var instructions: String
        var model: String
        var recap: String?
    }

    let providerID: ProviderID
    private let lock = NSLock()
    private var scriptedResults: [Result<String, ProviderFailure>] = []
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var shouldHoldNextAnswer = false
    private var recordedStarts: [StartCall] = []
    private var recordedTurns: [(turn: QuestionTurn, model: String)] = []
    private var recordedSummaries: [(text: String, instructions: String, model: String)] = []
    private var endCount = 0
    private var nextStartGate: TestGate?
    private var nextStartFailure: ProviderFailure?
    private var summaryResult: Result<String, ProviderFailure> = .success("You asked about the Save button.")
    private var scriptedStreams: [ScriptedStream] = []
    private var recordedRequests: [AnswerRequest] = []
    private var stopCount = 0
    private var pausedStreamContinuation: CheckedContinuation<Void, Never>?
    private var toolsAreSupported = false
    private var nextStopGate: TestGate?
    private var nextEndGate: TestGate?
    private var nextStartFailsWithOtherError = false

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

    /// One streamed answer for the fake to play: progress reports, an optional pause, then the whole answer.
    struct ScriptedStream {
        var progress: [AnswerProgress] = []
        /// After the progress reports the answer waits until `stopCurrentAnswer` or `releasePausedStream`.
        var pausesAfterProgress = false
        /// Reported after a stop, before the cut answer returns: late reports from an answer that was ended.
        var progressAfterStop: [AnswerProgress] = []
        var finalText = ""
        var secondsToFirstText: Double? = 0.4
        var toolCalls: [BrainToolCall] = []
        var notesRead: [String] = []
        var toolResultCharacterCount = 0
        /// Thrown after the progress reports (and the pause), the way a provider fails partway through an answer.
        var failureAfterProgress: ProviderFailure?
        /// After a stop the answer still returns whole and not cut short: the stop landed after the final text.
        var completesDespiteStop = false
        /// The answer ends early on its own (the repeat guard) with the text so far, cut short, with no stop asked.
        var endsEarlyOnItsOwn = false
        var effortWasApplied: Bool?
    }

    /// Streamed answers given in order to `answer`; once they run out it falls back to the `ask` script.
    func scriptStreams(_ streams: [ScriptedStream]) {
        lock.lock(); defer { lock.unlock() }
        scriptedStreams = streams
    }

    func releasePausedStream() {
        lock.lock()
        let continuation = pausedStreamContinuation
        pausedStreamContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    /// The next stopCurrentAnswer call waits at this gate before it ends the held answer, like an interrupt that is pending.
    func holdNextStop(at gate: TestGate) {
        lock.lock(); defer { lock.unlock() }
        nextStopGate = gate
    }

    func setSupportsBrainTools(_ supported: Bool) {
        lock.lock(); defer { lock.unlock() }
        toolsAreSupported = supported
    }

    var askedRequests: [AnswerRequest] { lock.lock(); defer { lock.unlock() }; return recordedRequests }
    var stopRequestCount: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    var supportsBrainTools: Bool { lock.lock(); defer { lock.unlock() }; return toolsAreSupported }

    // MARK: Script

    /// Answers given in order; once they run out, "Answer <n>." is returned.
    func script(_ results: [Result<String, ProviderFailure>]) {
        lock.lock(); defer { lock.unlock() }
        scriptedResults = results
    }

    func holdNextAnswer() {
        lock.lock(); defer { lock.unlock() }
        shouldHoldNextAnswer = true
    }

    func releaseHeldAnswer() {
        lock.lock()
        let continuation = heldContinuation
        heldContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    /// The next startConversation call waits at this gate until the test opens it.
    func holdNextStart(at gate: TestGate) {
        lock.lock(); defer { lock.unlock() }
        nextStartGate = gate
    }

    /// The next startConversation call throws this.
    func failNextStart(with failure: ProviderFailure) {
        lock.lock(); defer { lock.unlock() }
        nextStartFailure = failure
    }

    /// The next endConversation call is counted, then waits at this gate before it returns.
    func holdNextEnd(at gate: TestGate) {
        lock.lock(); defer { lock.unlock() }
        nextEndGate = gate
    }

    /// The next startConversation call throws an error that is not a ProviderFailure.
    func failNextStartWithOtherError() {
        lock.lock(); defer { lock.unlock() }
        nextStartFailsWithOtherError = true
    }

    func setSummaryResult(_ result: Result<String, ProviderFailure>) {
        lock.lock(); defer { lock.unlock() }
        summaryResult = result
    }

    // MARK: What happened

    var starts: [StartCall] { lock.lock(); defer { lock.unlock() }; return recordedStarts }
    var askedTurns: [QuestionTurn] { lock.lock(); defer { lock.unlock() }; return recordedTurns.map(\.turn) }
    var askedModels: [String] { lock.lock(); defer { lock.unlock() }; return recordedTurns.map(\.model) }
    var summaries: [(text: String, instructions: String, model: String)] {
        lock.lock(); defer { lock.unlock() }
        return recordedSummaries
    }
    var timesConversationEnded: Int { lock.lock(); defer { lock.unlock() }; return endCount }

    // MARK: AnswerProvider

    func startConversation(instructions: String, model: String, recap: String?) async throws {
        lock.lock()
        recordedStarts.append(StartCall(instructions: instructions, model: model, recap: recap))
        let gate = nextStartGate
        nextStartGate = nil
        let failure = nextStartFailure
        nextStartFailure = nil
        let failsWithOtherError = nextStartFailsWithOtherError
        nextStartFailsWithOtherError = false
        lock.unlock()
        await gate?.pass()
        if let failure { throw failure }
        if failsWithOtherError { throw CocoaError(.fileReadUnknown) }
    }

    func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer {
        lock.lock()
        recordedTurns.append((turn, model))
        let askNumber = recordedTurns.count
        let result = scriptedResults.isEmpty ? nil : scriptedResults.removeFirst()
        let mustHold = shouldHoldNextAnswer
        shouldHoldNextAnswer = false
        lock.unlock()

        if mustHold {
            await withCheckedContinuation { continuation in
                lock.lock()
                heldContinuation = continuation
                lock.unlock()
            }
        }
        switch result ?? .success("Answer \(askNumber).") {
        case .success(let text): return ProviderAnswer(text: text, model: model, secondsToAnswer: 2.5)
        case .failure(let failure): throw failure
        }
    }

    func answer(
        _ turn: QuestionTurn,
        request: AnswerRequest,
        progress: @escaping @Sendable (AnswerProgress) async -> Void
    ) async throws -> ProviderAnswer {
        lock.lock()
        recordedRequests.append(request)
        let stopsBefore = stopCount
        let stream = scriptedStreams.isEmpty ? nil : scriptedStreams.removeFirst()
        if stream != nil { recordedTurns.append((turn, request.model)) }
        lock.unlock()

        guard let stream else {
            // The ask script, reported the way the protocol default does, plus the stop flag.
            var whole = try await ask(turn, model: request.model)
            await progress(.textSoFar(whole.text))
            lock.lock(); whole.wasCutShort = stopCount > stopsBefore; lock.unlock()
            return whole
        }

        var latestRawText = ""
        for step in stream.progress {
            if case .textSoFar(let raw) = step { latestRawText = raw }
            await progress(step)
        }
        if stream.pausesAfterProgress {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if stopCount > stopsBefore {
                    lock.unlock()
                    continuation.resume()
                } else {
                    pausedStreamContinuation = continuation
                    lock.unlock()
                }
            }
        }
        lock.lock(); let wasStopped = stopCount > stopsBefore; lock.unlock()
        if let failure = stream.failureAfterProgress { throw failure }
        if stream.endsEarlyOnItsOwn {
            return ProviderAnswer(
                text: latestRawText, model: request.model, secondsToAnswer: 1.0,
                secondsToFirstText: stream.secondsToFirstText, toolCalls: stream.toolCalls,
                notesRead: stream.notesRead, toolResultCharacterCount: stream.toolResultCharacterCount,
                wasCutShort: true
            )
        }
        if wasStopped && !stream.completesDespiteStop {
            for step in stream.progressAfterStop { await progress(step) }
            return ProviderAnswer(
                text: latestRawText, model: request.model, secondsToAnswer: 1.0,
                secondsToFirstText: stream.secondsToFirstText, toolCalls: stream.toolCalls,
                notesRead: stream.notesRead, toolResultCharacterCount: stream.toolResultCharacterCount,
                wasCutShort: true
            )
        }
        return ProviderAnswer(
            text: stream.finalText, model: request.model, secondsToAnswer: 2.5,
            secondsToFirstText: stream.secondsToFirstText, toolCalls: stream.toolCalls,
            notesRead: stream.notesRead, toolResultCharacterCount: stream.toolResultCharacterCount,
            effortWasApplied: stream.effortWasApplied
        )
    }

    func stopCurrentAnswer() async {
        lock.lock()
        stopCount += 1
        let held = heldContinuation
        heldContinuation = nil
        let paused = pausedStreamContinuation
        pausedStreamContinuation = nil
        let gate = nextStopGate
        nextStopGate = nil
        lock.unlock()
        // A held stop is an interrupt still pending: the answer has not returned yet when the gate is closed.
        await gate?.pass()
        held?.resume()
        paused?.resume()
    }

    func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        lock.lock()
        recordedSummaries.append((text, instructions, model))
        let result = summaryResult
        lock.unlock()
        return try result.get()
    }

    func endConversation() async {
        lock.lock()
        endCount += 1
        let gate = nextEndGate
        nextEndGate = nil
        lock.unlock()
        await gate?.pass()
    }
}

/// Records what the flow tells the screen to show.
final class RecordingFlowOutput: SessionFlowOutput, @unchecked Sendable {
    struct Answer: Equatable {
        var spokenText: String
        var provider: ProviderID
        var model: String
        var secondsToAnswer: Double
        var pointLabel: String?
    }
    struct Pointer: Equatable {
        var globalPoint: CGPoint
        var displayFrameInPoints: CGRect
        var label: String?
    }

    private let lock = NSLock()
    private(set) var phases: [SessionFlowPhase] = []
    private(set) var questions: [String] = []
    private(set) var answers: [Answer] = []
    private(set) var notices: [String] = []
    private(set) var offers: [(message: String, switchTo: ProviderID)] = []
    private(set) var offerClearCount = 0
    private(set) var providerChanges: [(provider: ProviderID, model: String)] = []
    private(set) var pointers: [Pointer] = []
    private(set) var textChanges: [String] = []
    private(set) var checkingNotesCount = 0
    private(set) var answerNotesRead: [[String]] = []
    private(set) var cutShorts: [(visibleText: String, notesRead: [String])] = []
    private(set) var cutReasons: [AnswerCutReason] = []
    private(set) var toolCallStartedCount = 0
    /// Every streaming-related call in the order it happened: "text", "checking", "pointer", "answer", "cut".
    private(set) var callOrder: [String] = []
    /// Phases, cut-shorts, answers, notices and the harness's markQuestionStarted, in the order they happened.
    private(set) var timeline: [String] = []

    func recordTimeline(_ entry: String) { lock.lock(); timeline.append(entry); lock.unlock() }

    /// The answer number each answer report carried, in order, by report kind.
    private(set) var askedAnswerNumbers: [Int] = []
    private(set) var textAnswerNumbers: [Int] = []
    private(set) var cutAnswerNumbers: [Int] = []
    private(set) var finalAnswerNumbers: [Int] = []

    func answerTextChanged(answerNumber: Int, visibleText: String, provider: ProviderID, model: String) async {
        lock.lock(); textChanges.append(visibleText); textAnswerNumbers.append(answerNumber); callOrder.append("text")
        lock.unlock()
    }
    func checkingNotesShown(answerNumber: Int) async {
        lock.lock(); checkingNotesCount += 1; callOrder.append("checking"); lock.unlock()
    }
    func answerCutShort(
        answerNumber: Int, visibleText: String, provider: ProviderID, model: String, notesRead: [String],
        reason: AnswerCutReason
    ) async {
        lock.lock(); cutShorts.append((visibleText, notesRead)); cutReasons.append(reason); callOrder.append("cut")
        cutAnswerNumbers.append(answerNumber)
        timeline.append("cut"); lock.unlock()
    }
    func toolCallStarted(answerNumber: Int) async {
        lock.lock(); toolCallStartedCount += 1; lock.unlock()
    }

    func phaseChanged(_ phase: SessionFlowPhase) async {
        lock.lock(); phases.append(phase)
        if phase == .listening { timeline.append("listening") }
        var gate: TestGate?
        if let index = phaseGates.firstIndex(where: { $0.phase == phase }) { gate = phaseGates.remove(at: index).gate }
        lock.unlock()
        await gate?.pass()
    }
    private var phaseGates: [(phase: SessionFlowPhase, gate: TestGate)] = []
    /// The next time the flow reports this phase, the report waits at this gate (the flow has already moved on inside).
    func holdNextPhaseChange(to phase: SessionFlowPhase, at gate: TestGate) {
        lock.lock(); phaseGates.append((phase, gate)); lock.unlock()
    }
    func questionAsked(_ text: String, answerNumber: Int) async {
        lock.lock()
        questions.append(text)
        askedAnswerNumbers.append(answerNumber)
        let gate = questionAskedGate
        lock.unlock()
        await gate?.pass()
    }
    private var questionAskedGate: TestGate?
    /// The next questionAsked call waits at this gate, which is the moment between capture and ask.
    func holdQuestionAsked(at gate: TestGate) { lock.lock(); questionAskedGate = gate; lock.unlock() }
    func answerReceived(
        answerNumber: Int, spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double,
        pointLabel: String?, notesRead: [String]
    ) async {
        lock.lock()
        finalAnswerNumbers.append(answerNumber)
        answers.append(Answer(spokenText: spokenText, provider: provider, model: model,
                              secondsToAnswer: secondsToAnswer, pointLabel: pointLabel))
        answerNotesRead.append(notesRead)
        callOrder.append("answer"); timeline.append("answer")
        lock.unlock()
    }
    func noticeShown(_ text: String) async {
        lock.lock(); notices.append(text); timeline.append("notice")
        let gate = noticeGate
        noticeGate = nil
        lock.unlock()
        await gate?.pass()
    }
    private var noticeGate: TestGate?
    /// The next notice is recorded, then its report waits at this gate (Stop can land during the notice).
    func holdNextNotice(at gate: TestGate) { lock.lock(); noticeGate = gate; lock.unlock() }
    func usageLimitOffered(message: String, switchTo: ProviderID) async {
        lock.lock(); offers.append((message, switchTo)); lock.unlock()
    }
    func usageLimitOfferCleared() async { lock.lock(); offerClearCount += 1; lock.unlock() }
    func providerChanged(to provider: ProviderID, model: String) async {
        lock.lock(); providerChanges.append((provider, model)); lock.unlock()
    }
    func pointerRequested(globalPoint: CGPoint, displayFrameInPoints: CGRect, label: String?) async {
        lock.lock()
        pointers.append(Pointer(globalPoint: globalPoint, displayFrameInPoints: displayFrameInPoints, label: label))
        callOrder.append("pointer")
        lock.unlock()
    }
}

/// Collects the log lines the flow writes.
final class RecordedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SessionEvent] = []
    func append(_ event: SessionEvent) { lock.lock(); recorded.append(event); lock.unlock() }
    var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
    var kinds: [SessionEventKind] { events.map(\.kind) }
}

/// A flow wired to fake providers, a fake clock, a scripted transcription and a fixed screen.
final class FlowHarness: @unchecked Sendable {
    static let startTime = QuestionsFixtures.time(14, 0)

    let claude = FakeAnswerProvider(providerID: .claude)
    let chatgpt = FakeAnswerProvider(providerID: .chatgpt)
    let output = RecordingFlowOutput()
    let log = RecordedEventLog()
    let flow: SessionQuestionFlow
    /// When set, the next screen capture waits here until the test opens the gate.
    let captureHold = CaptureHold()
    /// When set, the next log write of a matching kind waits here until the test opens the gate.
    let logHold = LogHold()

    private let lock = NSLock()
    private var transcriptions: [String] = []
    private var clockSeconds = 0.0
    private var groupCounter = 0
    private var markedStarts: [Date] = []

    /// Questions are transcribed from these texts in order.
    init(
        questions: [String] = [], screenShots: [DisplayShot]? = nil, isBrainOn: Bool = false,
        passages: [BrainPassage] = [], brainMapPaths: [String] = [],
        digDeeperRequest: (@Sendable (ProviderID) async -> AnswerRequest)? = nil
    ) {
        transcriptions = questions
        let claudeProvider = claude
        let chatgptProvider = chatgpt
        let captureHold = self.captureHold
        let logHold = self.logHold
        let holder = state
        flow = SessionQuestionFlow(
            initialProvider: .claude,
            dependencies: SessionQuestionFlowDependencies(
                makeProvider: { id in id == .claude ? claudeProvider : chatgptProvider },
                model: { id in id == .claude ? "sonnet" : "gpt-test" },
                instructions: "Be brief.",
                markQuestionStarted: { [output] date in
                    holder.recordStart(date)
                    output.recordTimeline("markStarted")
                },
                transcribeQuestion: { [output] _, _ in
                    output.recordTimeline("transcribe")
                    if holder.takeTranscriptionFailure() { throw CocoaError(.fileReadUnknown) }
                    return holder.nextTranscription()
                },
                captureCurrentGroup: {
                    await captureHold.takeGate()?.pass()
                    if holder.takeCaptureFailure() { throw CocoaError(.fileReadUnknown) }
                    return holder.makeGroup(shots: screenShots)
                },
                logEvent: { [log] event in
                    await logHold.takeGate(for: event.kind)?.pass()
                    log.append(event)
                    await logHold.takeGateAfterWrite(for: event.kind)?.pass()
                },
                shotsDirectory: URL(fileURLWithPath: "/tmp/clicky-flow-test-shots", isDirectory: true),
                timeZone: QuestionsFixtures.utc,
                now: { holder.tick() },
                findPassages: { query, appName, windowTitle in
                    holder.recordPassageSearch(query: query, appName: appName, windowTitle: windowTitle)
                    return passages
                },
                isBrainOn: isBrainOn,
                brainMapPaths: { brainMapPaths },
                digDeeperRequest: digDeeperRequest
            ),
            output: output
        )
        holder.transcriptions = questions
    }

    private let state = HarnessState()

    /// The next question's transcription throws, or its screen capture throws.
    func failNextTranscription() { state.failNextTranscription() }
    func failNextCapture() { state.failNextCapture() }

    /// Every passage search the flow made, in order.
    var passageSearches: [(query: String, appName: String?, windowTitle: String?)] { state.passageSearches }

    /// Tap, then tap again, the way the question key reports them.
    @discardableResult
    func askQuestion() async -> SessionSignalOutcome {
        let started = Self.startTime.addingTimeInterval(1000)
        _ = await flow.handle(.questionStarted(at: started))
        return await flow.handle(.sendQuestion(speechFrom: started, speechTo: started.addingTimeInterval(3)))
    }
}

/// Lets a test hold the next screen capture.
final class CaptureHold: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: TestGate?
    func holdNextCapture(at newGate: TestGate) { lock.lock(); gate = newGate; lock.unlock() }
    func takeGate() -> TestGate? { lock.lock(); defer { lock.unlock() }; let held = gate; gate = nil; return held }
}

/// Lets a test hold the next log write of one kind, the moment between the flow's checks and its next output call.
final class LogHold: @unchecked Sendable {
    private let lock = NSLock()
    private var holds: [(matches: @Sendable (SessionEventKind) -> Bool, gate: TestGate)] = []
    func holdNextWrite(where matches: @escaping @Sendable (SessionEventKind) -> Bool, at gate: TestGate) {
        lock.lock(); holds.append((matches, gate)); lock.unlock()
    }
    private var holdsAfterWrite: [(matches: @Sendable (SessionEventKind) -> Bool, gate: TestGate)] = []
    /// Like `holdNextWrite`, but the line is already written when the gate holds: a log call that is slow to return.
    func holdNextWriteAfterItIsWritten(where matches: @escaping @Sendable (SessionEventKind) -> Bool, at gate: TestGate) {
        lock.lock(); holdsAfterWrite.append((matches, gate)); lock.unlock()
    }
    func takeGateAfterWrite(for kind: SessionEventKind) -> TestGate? {
        lock.lock(); defer { lock.unlock() }
        guard let index = holdsAfterWrite.firstIndex(where: { $0.matches(kind) }) else { return nil }
        return holdsAfterWrite.remove(at: index).gate
    }
    func takeGate(for kind: SessionEventKind) -> TestGate? {
        lock.lock(); defer { lock.unlock() }
        guard let index = holds.firstIndex(where: { $0.matches(kind) }) else { return nil }
        return holds.remove(at: index).gate
    }
}

/// Mutable bits behind the closures, kept in one lock so the harness stays Sendable.
final class HarnessState: @unchecked Sendable {
    private let lock = NSLock()
    var transcriptions: [String] = []
    private var seconds = 0.0
    private var groupCounter = 100
    private var starts: [Date] = []
    private var searches: [(query: String, appName: String?, windowTitle: String?)] = []

    func recordPassageSearch(query: String, appName: String?, windowTitle: String?) {
        lock.lock(); searches.append((query, appName, windowTitle)); lock.unlock()
    }
    var passageSearches: [(query: String, appName: String?, windowTitle: String?)] {
        lock.lock(); defer { lock.unlock() }; return searches
    }
    private var transcriptionFails = false
    private var captureFails = false
    func failNextTranscription() { lock.lock(); transcriptionFails = true; lock.unlock() }
    func failNextCapture() { lock.lock(); captureFails = true; lock.unlock() }
    func takeTranscriptionFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { transcriptionFails = false }
        return transcriptionFails
    }
    func takeCaptureFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { captureFails = false }
        return captureFails
    }
    func recordStart(_ date: Date) { lock.lock(); starts.append(date); lock.unlock() }
    func nextTranscription() -> String {
        lock.lock(); defer { lock.unlock() }
        return transcriptions.isEmpty ? "" : transcriptions.removeFirst()
    }
    func makeGroup(shots: [DisplayShot]?) -> ShotGroup {
        lock.lock(); defer { lock.unlock() }
        groupCounter += 1
        return QuestionsFixtures.group(
            id: groupCounter, capturedAt: FlowHarness.startTime.addingTimeInterval(1000),
            appName: "Xcode", windowTitle: "Clicky", shots: shots
        )
    }
    func tick() -> Date {
        lock.lock(); defer { lock.unlock() }
        seconds += 1
        return FlowHarness.startTime.addingTimeInterval(1000 + seconds)
    }
}
