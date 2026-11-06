import Foundation
import Testing
@testable import ClickyCore

@Suite("Session question flow: nothing reaches the app after Stop began")
struct SessionQuestionFlowAfterStopTests {
    private func startedHarness(questions: [String]) async throws -> FlowHarness {
        let harness = FlowHarness(questions: questions)
        try await harness.flow.begin()
        return harness
    }

    private func logEndsWithStop(_ harness: FlowHarness) -> Bool {
        if case .sessionStopped = harness.log.kinds.last { return true }
        return false
    }

    // MARK: A question shown after Stop

    /// Stop lands while the question line (or the passage line) is being logged (written, the call slow to return):
    /// the question was never shown, and no line follows the stop line.
    @Test(arguments: ["the question line", "the passage line"])
    func stopWhileTheQuestionIsBeingLoggedShowsNoQuestionAndSendsNothing(heldLine: String) async throws {
        let harness = FlowHarness(
            questions: ["where is the lease"], isBrainOn: true,
            passages: [BrainPassage(path: "/notes/lease.md", heading: "Term", startLine: 4, endLine: 9, text: "The lease ends in May.", score: 3)]
        )
        try await harness.flow.begin()
        let logGate = TestGate()
        harness.logHold.holdNextWriteAfterItIsWritten(where: { kind in
            switch kind {
            case .question: return heldLine == "the question line"
            case .passagesAttached: return heldLine == "the passage line"
            default: return false
            }
        }, at: logGate)

        let question = Task { await harness.askQuestion() }
        await logGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        logGate.open()
        _ = await question.value

        #expect(harness.output.questions.isEmpty)
        #expect(harness.output.askedAnswerNumbers.isEmpty)
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.cutShorts.isEmpty)
        #expect(!harness.output.phases.contains(.waitingForAnswer(provider: .claude)))
        #expect(harness.claude.askedTurns.isEmpty)
        #expect(harness.output.notices.isEmpty)
        #expect(logEndsWithStop(harness))
    }

    // MARK: A provider switch racing Stop

    @Test func stopDuringTheOldConversationsEndKeepsTheSummaryAndEndsEachProviderOnce() async throws {
        let harness = try await startedHarness(questions: ["first"])
        await harness.askQuestion()
        let endGate = TestGate()
        harness.claude.holdNextEnd(at: endGate)

        let switching = Task { await harness.flow.switchProvider(to: .chatgpt) }
        await endGate.waitUntilReached()
        let summaryTask = Task { await harness.flow.finish(summaryEnabled: true) }
        // Stop reaches its summary on the new provider while the old conversation is still ending.
        for _ in 0..<200 where harness.chatgpt.summaries.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        endGate.open()
        await switching.value
        let summary = await summaryTask.value

        #expect(summary == "You asked about the Save button.")
        #expect(harness.chatgpt.summaries.count == 1)
        #expect(harness.claude.summaries.isEmpty)
        #expect(harness.claude.timesConversationEnded == 1)
        #expect(harness.chatgpt.timesConversationEnded == 1)
        #expect(harness.output.providerChanges.isEmpty)
        #expect(harness.output.offerClearCount == 0)
        #expect(logEndsWithStop(harness))
    }

    // MARK: A phase change after Stop

    /// Runs one question whose early exit shows a notice, lands Stop during that notice, and returns the harness.
    private func stopDuringTheNotice(
        questions: [String], beforeTheQuestion: (FlowHarness) async -> Void
    ) async throws -> (FlowHarness, phasesWhenStopBegan: [SessionFlowPhase]) {
        let harness = try await startedHarness(questions: questions)
        await beforeTheQuestion(harness)
        let noticeGate = TestGate()
        harness.output.holdNextNotice(at: noticeGate)
        let question = Task { await harness.askQuestion() }
        await noticeGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        let phasesWhenStopBegan = harness.output.phases
        noticeGate.open()
        _ = await question.value
        return (harness, phasesWhenStopBegan)
    }

    @Test func stopDuringTheEmptyTranscriptNoticeReportsNoPhase() async throws {
        let (harness, before) = try await stopDuringTheNotice(questions: [""]) { _ in }
        #expect(harness.output.notices == ["Didn't catch that"])
        #expect(harness.output.phases == before)
    }

    @Test func stopDuringTheTranscriptionFailureNoticeReportsNoPhase() async throws {
        let (harness, before) = try await stopDuringTheNotice(questions: ["q"]) { $0.failNextTranscription() }
        #expect(harness.output.notices == ["Could not hear that. Try again."])
        #expect(harness.output.phases == before)
    }

    @Test func stopDuringTheCaptureFailureNoticeReportsNoPhase() async throws {
        let (harness, before) = try await stopDuringTheNotice(questions: ["q"]) { $0.failNextCapture() }
        #expect(harness.output.notices == ["The screen could not be captured."])
        #expect(harness.output.phases == before)
    }

    private func answerFifteenQuestions(_ harness: FlowHarness) async {
        for _ in 1...15 { await harness.askQuestion() }
    }

    @Test func stopDuringTheRestartFailureNoticeReportsNoPhase() async throws {
        let (harness, before) = try await stopDuringTheNotice(questions: (1...16).map { "question \($0)" }) { harness in
            await answerFifteenQuestions(harness)
            harness.claude.failNextStart(with: .notSignedIn)
        }
        #expect(harness.output.notices.count == 1)
        #expect(harness.output.phases == before)
    }

    @Test func stopDuringTheRestartOtherErrorNoticeReportsNoPhase() async throws {
        let (harness, before) = try await stopDuringTheNotice(questions: (1...16).map { "question \($0)" }) { harness in
            await answerFifteenQuestions(harness)
            harness.claude.failNextStartWithOtherError()
        }
        #expect(harness.output.notices == ["The conversation could not be restarted."])
        #expect(harness.output.phases == before)
    }
}
