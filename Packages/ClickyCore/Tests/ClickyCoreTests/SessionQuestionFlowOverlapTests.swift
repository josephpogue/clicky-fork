import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 1, group FX3: a new question while an answer is coming, failures after text, and what the log says.
@Suite("Session question flow: overlapping questions, failures after text and the log")
struct SessionQuestionFlowOverlapTests {
    private typealias Stream = FakeAnswerProvider.ScriptedStream

    private static let leasePassage = BrainPassage(
        path: "/notes/lease.md", heading: "Term", startLine: 4, endLine: 9, text: "The lease ends in May.", score: 3
    )

    private func startedHarness(
        questions: [String], isBrainOn: Bool = false,
        digDeeperRequest: (@Sendable (ProviderID) async -> AnswerRequest)? = nil
    ) async throws -> FlowHarness {
        let harness = FlowHarness(
            questions: questions, isBrainOn: isBrainOn, passages: isBrainOn ? [Self.leasePassage] : [],
            digDeeperRequest: digDeeperRequest
        )
        try await harness.flow.begin()
        return harness
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Taps the question key a second time. When the tap does not come back within 1.5 seconds (the flow is stuck
    /// waiting on the old answer's stop) the gate is opened so the test ends instead of hanging.
    private func tapReturningWithin(
        _ harness: FlowHarness, unsticking gate: TestGate
    ) async -> (outcome: SessionSignalOutcome, returnedInTime: Bool) {
        let finished = Finished()
        let task = Task { () -> SessionSignalOutcome in
            let outcome = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime.addingTimeInterval(5)))
            finished.set()
            return outcome
        }
        for _ in 0..<150 where !finished.isSet { try? await Task.sleep(nanoseconds: 10_000_000) }
        let returnedInTime = finished.isSet
        if !returnedInTime { gate.open() }
        return (await task.value, returnedInTime)
    }

    /// The second question's listening phase comes first, and the marker call comes right after it.
    private func secondListeningIsFollowedByTheMarker(_ harness: FlowHarness) -> Bool {
        let timeline = harness.output.timeline
        let listeningIndexes = timeline.indices.filter { timeline[$0] == "listening" }
        guard listeningIndexes.count == 2, listeningIndexes[1] + 1 < timeline.count else { return false }
        return timeline[listeningIndexes[1] + 1] == "markStarted"
    }

    private func kindCount(_ harness: FlowHarness, _ matches: (SessionEventKind) -> Bool) -> Int {
        harness.log.kinds.filter(matches).count
    }

    // MARK: Finding 1: a new question shows listening first and stops the old answer off the listening path

    @Test func aNewQuestionShowsListeningAndMarksTheStartWhileTheOldAnswerIsStillBeingStopped() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        let stopGate = TestGate()
        harness.claude.holdNextStop(at: stopGate)
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Partial answer")], pausesAfterProgress: true),
            Stream(progress: [.textSoFar("Second answer.")], finalText: "Second answer."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }

        let (outcome, returnedInTime) = await tapReturningWithin(harness, unsticking: stopGate)

        // The stop is still held open, yet the tap came back, and listening, the marker and the log line are all in.
        #expect(returnedInTime)
        #expect(outcome == .accepted)
        #expect(harness.output.phases.last == .listening)
        #expect(secondListeningIsFollowedByTheMarker(harness))
        #expect(kindCount(harness) { $0 == .questionStarted } == 2)

        // The second tap sends the question; it waits for the stop before it is transcribed.
        let send = Task {
            await harness.flow.handle(.sendQuestion(
                speechFrom: FlowHarness.startTime, speechTo: FlowHarness.startTime.addingTimeInterval(3)
            ))
        }
        try await waitUntil { harness.output.phases.last == .transcribing }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(harness.output.timeline.filter { $0 == "transcribe" }.count == 1)
        stopGate.open()
        _ = await send.value
        _ = await first.value

        #expect(harness.output.timeline.filter { $0 == "transcribe" }.count == 2)
        #expect(harness.output.answers.map(\.spokenText) == ["Second answer."])
        #expect(harness.output.cutReasons == [.newerQuestion])
        // The old answer reached the log before the new question was transcribed, and the new question is logged.
        let kinds = harness.log.kinds
        let cutIndex = try #require(kinds.firstIndex(of: .answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: true)))
        let questionIndex = try #require(kinds.firstIndex {
            if case .question(let text, _, _) = $0 { return text == "second question" } else { return false }
        })
        #expect(cutIndex < questionIndex)
        let startedIndexes = kinds.indices.filter { kinds[$0] == .questionStarted }
        #expect(startedIndexes.count == 2 && startedIndexes[1] < questionIndex)
    }

    @Test(arguments: [
        "before the first text", "during a tool call", "after the final text", "while the interrupt is pending",
    ])
    func aNewQuestionInEveryStateOfTheOldAnswerListensFirstAndAnswersAfterTheStop(state: String) async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        let stopGate = TestGate()
        let progress: [AnswerProgress]
        switch state {
        case "before the first text": progress = []
        case "during a tool call": progress = [.textSoFar("Looking."), .toolCallStarted(.searchBrain)]
        default: progress = [.textSoFar("The whole answer.")]
        }
        harness.claude.scriptStreams([
            Stream(
                progress: progress, pausesAfterProgress: true,
                finalText: "The whole answer.", completesDespiteStop: state == "after the final text"
            ),
            Stream(progress: [.textSoFar("Second answer.")], finalText: "Second answer."),
        ])
        if state == "while the interrupt is pending" { harness.claude.holdNextStop(at: stopGate) }
        let first = Task { await harness.askQuestion() }
        try await waitUntil { harness.output.phases.contains(.waitingForAnswer(provider: .claude)) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let (_, returnedInTime) = await tapReturningWithin(harness, unsticking: stopGate)
        #expect(returnedInTime)
        #expect(secondListeningIsFollowedByTheMarker(harness))
        let send = Task {
            await harness.flow.handle(.sendQuestion(
                speechFrom: FlowHarness.startTime, speechTo: FlowHarness.startTime.addingTimeInterval(3)
            ))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        stopGate.open()
        _ = await send.value
        _ = await first.value

        #expect(harness.output.answers.map(\.spokenText) == ["Second answer."])
        #expect(harness.output.phases.last == .idle)
        #expect(await harness.flow.answeredQuestionCount == 1)
    }

    @Test func twoNewQuestionsInARowEndEachOldAnswerAndOnlyTheLastOneAnswers() async throws {
        let harness = try await startedHarness(questions: ["one", "two", "three"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("First partial")], pausesAfterProgress: true),
            Stream(progress: [.textSoFar("Second partial")], pausesAfterProgress: true),
            Stream(progress: [.textSoFar("Third.")], finalText: "Third."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { harness.output.textChanges.contains("First partial") }
        let second = Task { await harness.askQuestion() }
        try await waitUntil { harness.output.textChanges.contains("Second partial") }
        await harness.askQuestion()
        _ = await first.value
        _ = await second.value

        #expect(harness.output.answers.map(\.spokenText) == ["Third."])
        #expect(harness.output.cutReasons == [.newerQuestion, .newerQuestion])
        #expect(harness.claude.stopRequestCount == 2)
        #expect(kindCount(harness) { $0 == .questionStarted } == 3)
    }

    // MARK: Finding 5: Stop while a new question's stop is still pending

    @Test func stopWhileTheNewQuestionsStopIsPendingStillLogsTheOldPartialAnswerBeforeTheStopLine() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        let stopGate = TestGate()
        harness.claude.holdNextStop(at: stopGate)
        harness.claude.scriptStreams([Stream(progress: [.textSoFar("Partial answer")], pausesAfterProgress: true)])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        let tap = Task { await harness.flow.handle(.questionStarted(at: FlowHarness.startTime.addingTimeInterval(5))) }
        try await waitUntil { harness.claude.stopRequestCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Stop arrives while the interrupt is still pending.
        let finishing = Task { await harness.flow.finish(summaryEnabled: false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        stopGate.open()
        _ = await finishing.value
        _ = await tap.value
        _ = await first.value

        let kinds = harness.log.kinds
        #expect(kinds.contains(.answer(text: "Partial answer", provider: .claude, model: "sonnet", secondsToAnswer: 1.0, pointLabel: nil)))
        #expect(kinds.last == .sessionStopped)
        // Stop is silent on the screen, as before.
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.notices.isEmpty)
    }

    @Test func stopWhileTheNewQuestionIsTranscribingStillLogsTheOldPartialAnswer() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([Stream(progress: [.textSoFar("Partial answer")], pausesAfterProgress: true)])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        _ = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime.addingTimeInterval(5)))
        let captureGate = TestGate()
        harness.captureHold.holdNextCapture(at: captureGate)
        let send = Task {
            await harness.flow.handle(.sendQuestion(
                speechFrom: FlowHarness.startTime, speechTo: FlowHarness.startTime.addingTimeInterval(3)
            ))
        }
        await captureGate.waitUntilReached()

        _ = await harness.flow.finish(summaryEnabled: false)
        captureGate.open()
        _ = await send.value
        _ = await first.value

        let kinds = harness.log.kinds
        #expect(kinds.contains(.answer(text: "Partial answer", provider: .claude, model: "sonnet", secondsToAnswer: 1.0, pointLabel: nil)))
        #expect(kinds.last == .sessionStopped)
        #expect(harness.claude.askedTurns.count == 1)
    }

    // MARK: Finding 2: an answer that fails after text finishes the message first

    @Test func aFailureAfterTextCutsTheMessageShortBeforeTheNotice() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.scriptStreams([Stream(
            progress: [.textSoFar("Half an ans")], failureAfterProgress: .failed(message: "Claude stopped before answering.")
        )])

        await harness.askQuestion()

        #expect(harness.output.cutShorts.map(\.visibleText) == ["Half an ans"])
        #expect(harness.output.cutReasons == [.failed])
        #expect(harness.output.notices == ["Claude stopped before answering."])
        #expect(harness.output.timeline == ["listening", "markStarted", "transcribe", "cut", "notice"])
        #expect(harness.output.answers.isEmpty)
    }

    @Test func aUsageLimitAfterTextCutsTheMessageShortAndStillOffersTheSwitch() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.scriptStreams([Stream(
            progress: [.textSoFar("Half an ans")], failureAfterProgress: .usageLimitReached(message: "limit")
        )])

        await harness.askQuestion()

        #expect(harness.output.cutReasons == [.failed])
        #expect(harness.output.offers.count == 1)
    }

    @Test func aFailureWithNoTextShowsOnlyTheNotice() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.scriptStreams([Stream(failureAfterProgress: .failed(message: "broke"))])

        await harness.askQuestion()

        #expect(harness.output.cutShorts.isEmpty)
        #expect(harness.output.notices == ["broke"])
    }

    @Test func aFailureOfAnAnswerANewerQuestionEndedShowsNoCutShortAndNoNotice() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Half")], pausesAfterProgress: true, failureAfterProgress: .failed(message: "late")),
            Stream(progress: [.textSoFar("Second.")], finalText: "Second."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        await harness.askQuestion()
        _ = await first.value

        #expect(harness.output.cutShorts.isEmpty)
        #expect(harness.output.notices.isEmpty)
        #expect(harness.output.answers.map(\.spokenText) == ["Second."])
    }

    @Test func aGuardEndedAnswerWithTextIsCutShortAsFailedAndNotShownAsComplete() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.scriptStreams([Stream(progress: [.textSoFar("Looking.")], endsEarlyOnItsOwn: true)])

        await harness.askQuestion()

        #expect(harness.output.cutShorts.map(\.visibleText) == ["Looking."])
        #expect(harness.output.cutReasons == [.failed])
        #expect(harness.output.answers.isEmpty)
        #expect(harness.log.kinds.contains(.answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: true)))
        #expect(harness.output.phases.last == .idle)
    }

    @Test func aGuardEndedAnswerWithNoTextIsTheNoAnswerFailureAsToday() async throws {
        let harness = try await startedHarness(questions: ["first question"])
        harness.claude.scriptStreams([Stream(endsEarlyOnItsOwn: true)])

        await harness.askQuestion()

        #expect(harness.output.cutShorts.isEmpty)
        #expect(harness.output.notices == ["No answer came back. Try again."])
    }

    // MARK: Finding 3: dig deeper needs the brain on

    @Test func digDeeperWithTheBrainOffIsAnOrdinaryQuestion() async throws {
        let harness = try await startedHarness(
            questions: ["what is the lease term", "dig deeper on the deposit"], isBrainOn: false,
            digDeeperRequest: { _ in AnswerRequest(model: "opus", effort: .high) }
        )

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.claude.askedRequests == [AnswerRequest(model: "sonnet"), AnswerRequest(model: "sonnet")])
        #expect(harness.passageSearches.isEmpty)
        #expect(kindCount(harness) { if case .digDeeperAsked = $0 { return true } else { return false } } == 0)
    }

    // MARK: Finding 6: a cut answer still fills the conversation

    @Test func aCutAnswersToolResultsCountTowardsTheConversationLimit() async throws {
        let harness = try await startedHarness(questions: ["first", "second", "third"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Partial")], pausesAfterProgress: true, toolResultCharacterCount: 170_000),
            Stream(progress: [.textSoFar("Second.")], finalText: "Second."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        await harness.askQuestion()
        _ = await first.value

        // The cut answer's 170,000 characters used up the limit, so the second question began a fresh conversation.
        #expect(harness.claude.starts.count == 2)
        await harness.askQuestion()
        #expect(harness.claude.starts.count == 2)
    }

    // MARK: Finding 7: the log says what happened to the answer

    @Test func anAnswerThatCompletedDespiteTheNewQuestionIsLoggedAsCompleteAndNotShown() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(
                progress: [.textSoFar("The whole answer.")], pausesAfterProgress: true,
                finalText: "The whole answer.", completesDespiteStop: true
            ),
            Stream(progress: [.textSoFar("Second.")], finalText: "Second."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        await harness.askQuestion()
        _ = await first.value

        let kinds = harness.log.kinds
        #expect(kinds.contains(.answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: false)))
        #expect(!kinds.contains(.answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: true)))
        #expect(harness.output.answers.map(\.spokenText) == ["Second."])
        #expect(harness.output.cutShorts.isEmpty)
    }

    @Test func anAnswerCutByANewerQuestionIsStillLoggedAsCutShort() async throws {
        let harness = try await startedHarness(questions: ["first question", "second question"])
        harness.claude.scriptStreams([
            Stream(progress: [.textSoFar("Partial")], pausesAfterProgress: true),
            Stream(progress: [.textSoFar("Second.")], finalText: "Second."),
        ])
        let first = Task { await harness.askQuestion() }
        try await waitUntil { !harness.output.textChanges.isEmpty }
        await harness.askQuestion()
        _ = await first.value

        #expect(harness.log.kinds.contains(.answerTiming(secondsToFirstText: 0.4, toolCallCount: 0, wasCutShort: true)))
        #expect(harness.output.cutReasons == [.newerQuestion])
    }

    // MARK: Finding 8: the pointer follows the final tag

    @Test func aLaterTagInACorrectionMovesThePointerToTheFinalSpot() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        let first = "It is the Save button. [POINT:100,100:save button:screen1]"
        let corrected = first + " Correction: it is the Share button. [POINT:1180,40:share button:screen1]"
        harness.claude.scriptStreams([Stream(progress: [.textSoFar(first), .textSoFar(corrected)], finalText: corrected)])

        await harness.askQuestion()

        #expect(harness.output.pointers.count == 2)
        #expect(harness.output.pointers.last?.label == "share button")
        #expect(harness.output.pointers.last?.globalPoint == CGPoint(x: 1327.5, y: 855))
        #expect(harness.output.answers.first?.pointLabel == "share button")
    }

    @Test func aFinalTagThatMatchesTheStreamedOneFliesOnlyOnce() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        let text = "It is the Save button. [POINT:1180,40:save button:screen1]"
        harness.claude.scriptStreams([Stream(progress: [.textSoFar(text)], finalText: text)])

        await harness.askQuestion()

        #expect(harness.output.pointers.count == 1)
    }

    @Test func aCorrectionTagThatIsPointNoneLeavesTheStreamedPointer() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        let first = "It is the Save button. [POINT:100,100:save button:screen1]"
        let corrected = first + " Never mind. [POINT:none]"
        harness.claude.scriptStreams([Stream(progress: [.textSoFar(first), .textSoFar(corrected)], finalText: corrected)])

        await harness.askQuestion()

        #expect(harness.output.pointers.count == 1)
    }

    // MARK: Finding 9: the log names the effort that was applied

    @Test func theDigDeeperLineNamesTheEffortTheProviderAppliedAndNotTheOneAskedFor() async throws {
        let harness = try await startedHarness(
            questions: ["dig deeper on the deposit"], isBrainOn: true,
            digDeeperRequest: { _ in AnswerRequest(model: "opus", effort: .high) }
        )
        harness.claude.scriptStreams([Stream(finalText: "Done.", effortWasApplied: false)])

        await harness.askQuestion()

        let kinds = harness.log.kinds
        #expect(kinds.contains(.digDeeperAsked(model: "opus", effort: nil)))
        #expect(!kinds.contains(.digDeeperAsked(model: "opus", effort: "high")))
    }

    @Test func theDigDeeperLineKeepsTheAskedEffortWhenTheProviderAppliedItOrDoesNotSay() async throws {
        let harness = try await startedHarness(
            questions: ["dig deeper on the deposit", "dig deeper again"], isBrainOn: true,
            digDeeperRequest: { _ in AnswerRequest(model: "opus", effort: .high) }
        )
        harness.claude.scriptStreams([
            Stream(finalText: "Done.", effortWasApplied: true), Stream(finalText: "Again."),
        ])

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(kindCount(harness) { $0 == .digDeeperAsked(model: "opus", effort: "high") } == 2)
    }
}
