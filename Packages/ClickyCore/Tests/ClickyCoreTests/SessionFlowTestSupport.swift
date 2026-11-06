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

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

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
        lock.unlock()
        await gate?.pass()
        if let failure { throw failure }
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

    func summarize(_ text: String, instructions: String, model: String) async throws -> String {
        lock.lock()
        recordedSummaries.append((text, instructions, model))
        let result = summaryResult
        lock.unlock()
        return try result.get()
    }

    func endConversation() async {
        lock.lock(); defer { lock.unlock() }
        endCount += 1
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

    func phaseChanged(_ phase: SessionFlowPhase) async { lock.lock(); phases.append(phase); lock.unlock() }
    func questionAsked(_ text: String) async {
        lock.lock()
        questions.append(text)
        let gate = questionAskedGate
        lock.unlock()
        await gate?.pass()
    }
    private var questionAskedGate: TestGate?
    /// The next questionAsked call waits at this gate, which is the moment between capture and ask.
    func holdQuestionAsked(at gate: TestGate) { lock.lock(); questionAskedGate = gate; lock.unlock() }
    func answerReceived(
        spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double, pointLabel: String?,
        notesRead: [String]
    ) async {
        lock.lock()
        answers.append(Answer(spokenText: spokenText, provider: provider, model: model,
                              secondsToAnswer: secondsToAnswer, pointLabel: pointLabel))
        lock.unlock()
    }
    func noticeShown(_ text: String) async { lock.lock(); notices.append(text); lock.unlock() }
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

    private let lock = NSLock()
    private var transcriptions: [String] = []
    private var clockSeconds = 0.0
    private var groupCounter = 0
    private var markedStarts: [Date] = []

    /// Questions are transcribed from these texts in order.
    init(questions: [String] = [], screenShots: [DisplayShot]? = nil) {
        transcriptions = questions
        let claudeProvider = claude
        let chatgptProvider = chatgpt
        let captureHold = self.captureHold
        let holder = HarnessState()
        flow = SessionQuestionFlow(
            initialProvider: .claude,
            dependencies: SessionQuestionFlowDependencies(
                makeProvider: { id in id == .claude ? claudeProvider : chatgptProvider },
                model: { id in id == .claude ? "sonnet" : "gpt-test" },
                instructions: "Be brief.",
                markQuestionStarted: { date in holder.recordStart(date) },
                transcribeQuestion: { _, _ in holder.nextTranscription() },
                captureCurrentGroup: {
                    await captureHold.takeGate()?.pass()
                    return holder.makeGroup(shots: screenShots)
                },
                logEvent: { [log] event in log.append(event) },
                shotsDirectory: URL(fileURLWithPath: "/tmp/clicky-flow-test-shots", isDirectory: true),
                timeZone: QuestionsFixtures.utc,
                now: { holder.tick() }
            ),
            output: output
        )
        holder.transcriptions = questions
    }

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

/// Mutable bits behind the closures, kept in one lock so the harness stays Sendable.
final class HarnessState: @unchecked Sendable {
    private let lock = NSLock()
    var transcriptions: [String] = []
    private var seconds = 0.0
    private var groupCounter = 100
    private var starts: [Date] = []

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
