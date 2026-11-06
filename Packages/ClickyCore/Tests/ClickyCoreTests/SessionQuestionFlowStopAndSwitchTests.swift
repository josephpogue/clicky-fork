import Foundation
import Testing
@testable import ClickyCore

@Suite("Session question flow: Stop races, switching and empty answers")
struct SessionQuestionFlowStopAndSwitchTests {
    private func startedHarness(questions: [String]) async throws -> FlowHarness {
        let harness = FlowHarness(questions: questions)
        try await harness.flow.begin()
        return harness
    }

    private func questionLogCount(_ harness: FlowHarness) -> Int {
        harness.log.kinds.filter { if case .question = $0 { return true } else { return false } }.count
    }

    private func answerLogCount(_ harness: FlowHarness) -> Int {
        harness.log.kinds.filter { if case .answer = $0 { return true } else { return false } }.count
    }

    /// Nothing may be logged after the stop line.
    private func logEndsWithStop(_ harness: FlowHarness) -> Bool {
        if case .sessionStopped = harness.log.kinds.last { return true }
        return false
    }

    // MARK: Stop races inside a question

    @Test func stopDuringTheFreshConversationRestartSendsNothingAndEndsTheRestartedConversation() async throws {
        let harness = try await startedHarness(questions: (1...16).map { "question \($0)" })
        for _ in 1...15 { await harness.askQuestion() }
        let restartGate = TestGate()
        harness.claude.holdNextStart(at: restartGate)

        let sixteenth = Task { await harness.askQuestion() }
        await restartGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        let endsAfterStop = harness.claude.timesConversationEnded
        restartGate.open()
        _ = await sixteenth.value

        // 1 end before the restart, 1 from Stop, and 1 for the conversation the restart started after Stop.
        #expect(endsAfterStop == 2)
        #expect(harness.claude.timesConversationEnded == 3)
        #expect(harness.claude.askedTurns.count == 15)
        #expect(questionLogCount(harness) == 15)
        #expect(harness.output.notices.isEmpty)
        #expect(logEndsWithStop(harness))
    }

    @Test func aRestartThatFailsAfterStopShowsNoNotice() async throws {
        let harness = try await startedHarness(questions: (1...16).map { "question \($0)" })
        for _ in 1...15 { await harness.askQuestion() }
        let restartGate = TestGate()
        harness.claude.holdNextStart(at: restartGate)
        harness.claude.failNextStart(with: .failed(message: "restart broke"))

        let sixteenth = Task { await harness.askQuestion() }
        await restartGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        restartGate.open()
        _ = await sixteenth.value

        #expect(harness.output.notices.isEmpty)
        #expect(harness.claude.askedTurns.count == 15)
    }

    @Test func aRestartThatFailsShowsTheFailureAndTheNextQuestionTriesTheRestartAgain() async throws {
        let harness = try await startedHarness(questions: (1...17).map { "question \($0)" })
        for _ in 1...15 { await harness.askQuestion() }
        harness.claude.failNextStart(with: .failed(message: "restart broke"))

        await harness.askQuestion()

        #expect(harness.output.notices == ["restart broke"])
        #expect(harness.claude.askedTurns.count == 15)
        #expect(questionLogCount(harness) == 15)
        #expect(harness.output.phases.last == .idle)

        await harness.askQuestion()

        // The failed restart left the budget spent, so the next question restarts again, then asks.
        #expect(harness.claude.starts.count == 3)
        #expect(harness.claude.askedTurns.count == 16)
    }

    @Test func stopDuringTheScreenCaptureSendsAndLogsNothing() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        let captureGate = TestGate()
        harness.captureHold.holdNextCapture(at: captureGate)

        let question = Task { await harness.askQuestion() }
        await captureGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        captureGate.open()
        _ = await question.value

        #expect(harness.claude.askedTurns.isEmpty)
        #expect(questionLogCount(harness) == 0)
        #expect(harness.output.questions.isEmpty)
        #expect(harness.output.notices.isEmpty)
        #expect(logEndsWithStop(harness))
    }

    @Test func stopBetweenCaptureAndAskNeverSendsTheQuestion() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        let beforeAskGate = TestGate()
        harness.output.holdQuestionAsked(at: beforeAskGate)

        let question = Task { await harness.askQuestion() }
        await beforeAskGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        beforeAskGate.open()
        _ = await question.value

        #expect(harness.claude.askedTurns.isEmpty)
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.notices.isEmpty)
        #expect(!harness.output.phases.contains(.waitingForAnswer(provider: .claude)))
    }

    @Test func anAnswerEndedByStopIsLoggedBeforeTheStopLineAndNeverShown() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        harness.claude.holdNextAnswer()

        let question = Task { await harness.askQuestion() }
        for _ in 0..<200 where harness.claude.askedTurns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = await harness.flow.finish(summaryEnabled: false)
        harness.claude.releaseHeldAnswer()
        _ = await question.value

        #expect(harness.claude.stopRequestCount == 1)
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.cutShorts.isEmpty)
        #expect(answerLogCount(harness) == 1)
        #expect(await harness.flow.answeredQuestionCount == 0)
        #expect(logEndsWithStop(harness))
    }

    @Test func aFailureThatLandsAfterStopIsNeitherShownNorLogged() async throws {
        let harness = try await startedHarness(questions: ["where is it"])
        harness.claude.script([.failure(.failed(message: "late failure"))])
        harness.claude.holdNextAnswer()

        let question = Task { await harness.askQuestion() }
        for _ in 0..<200 where harness.claude.askedTurns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = await harness.flow.finish(summaryEnabled: false)
        harness.claude.releaseHeldAnswer()
        _ = await question.value

        #expect(harness.output.notices.isEmpty)
        #expect(logEndsWithStop(harness))
    }

    // MARK: The note since the last question survives a failed answer

    @Test func theNoteSinceTheLastQuestionRidesOnTheRetryAfterAFailedAnswer() async throws {
        let harness = try await startedHarness(questions: ["first try", "second try", "third try"])
        harness.claude.script([.failure(.failed(message: "no luck")), .success("Done."), .success("Done again.")])
        let spokenAt = FlowHarness.startTime.addingTimeInterval(500)
        await harness.flow.noteEvent(SessionEvent(time: spokenAt, kind: .utterance(text: "this looks wrong")))

        await harness.askQuestion()
        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.claude.askedTurns[0].contextNote.contains("this looks wrong"))
        #expect(harness.claude.askedTurns[1].contextNote.contains("this looks wrong"))
        // Once an answer came back the note is spent.
        #expect(harness.claude.askedTurns[2].contextNote == "")
    }

    @Test func eventsThatLandWhileAnAnswerIsPendingWaitForTheNextQuestion() async throws {
        let harness = try await startedHarness(questions: ["first", "second"])
        harness.claude.holdNextAnswer()
        let question = Task { await harness.askQuestion() }
        for _ in 0..<200 where harness.claude.askedTurns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        await harness.flow.noteEvent(SessionEvent(
            time: FlowHarness.startTime.addingTimeInterval(1500), kind: .utterance(text: "said while waiting")
        ))
        harness.claude.releaseHeldAnswer()
        _ = await question.value

        await harness.askQuestion()

        #expect(harness.claude.askedTurns[1].contextNote.contains("said while waiting"))
    }

    // MARK: Empty answers

    @Test func anAnswerOfOnlyATagShowsAFailureNoticeAndCountsAsNoExchange() async throws {
        let harness = try await startedHarness(questions: ["what now"])
        harness.claude.script([.success("[POINT:none]")])

        await harness.askQuestion()

        #expect(harness.output.notices == ["No answer came back. Try again."])
        #expect(harness.output.answers.isEmpty)
        #expect(harness.output.pointers.isEmpty)
        #expect(answerLogCount(harness) == 0)
        #expect(await harness.flow.answeredQuestionCount == 0)
        #expect(harness.output.phases.last == .idle)
    }

    @Test func aBlankAnswerIsTheSameAsAnEmptyOne() async throws {
        let harness = try await startedHarness(questions: ["what now"])
        harness.claude.script([.success("  \n ")])

        await harness.askQuestion()

        #expect(harness.output.notices == ["No answer came back. Try again."])
        #expect(await harness.flow.answeredQuestionCount == 0)
    }

    @Test func anEmptyAnswerKeepsTheNoteForTheRetry() async throws {
        let harness = try await startedHarness(questions: ["one", "two"])
        harness.claude.script([.success("[POINT:none]"), .success("Real answer.")])
        await harness.flow.noteEvent(SessionEvent(
            time: FlowHarness.startTime.addingTimeInterval(500), kind: .utterance(text: "keep this")
        ))

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.claude.askedTurns[1].contextNote.contains("keep this"))
        #expect(await harness.flow.answeredQuestionCount == 1)
    }

    // MARK: One-tap switch

    private func usageLimitedHarness(questions: [String]) async throws -> FlowHarness {
        let harness = try await startedHarness(questions: questions)
        harness.claude.script([.failure(.usageLimitReached(message: "limit"))])
        await harness.askQuestion()
        return harness
    }

    @Test func aDoubleTapOnSwitchStartsOneChatGPTConversation() async throws {
        let harness = try await usageLimitedHarness(questions: ["first"])
        let startGate = TestGate()
        harness.chatgpt.holdNextStart(at: startGate)

        let firstTap = Task { await harness.flow.switchProvider(to: .chatgpt) }
        await startGate.waitUntilReached()
        await harness.flow.switchProvider(to: .chatgpt)
        startGate.open()
        await firstTap.value

        #expect(harness.chatgpt.starts.count == 1)
        #expect(harness.output.providerChanges.count == 1)
        let switchedLines = harness.log.kinds.filter { if case .providerSwitched = $0 { return true } else { return false } }
        #expect(switchedLines.count == 1)
        #expect(harness.claude.timesConversationEnded == 1)
        #expect(await harness.flow.currentProvider == .chatgpt)
    }

    @Test func stopDuringTheSwitchEndsTheNewConversationAndChangesNothing() async throws {
        let harness = try await usageLimitedHarness(questions: ["first"])
        let startGate = TestGate()
        harness.chatgpt.holdNextStart(at: startGate)

        let switching = Task { await harness.flow.switchProvider(to: .chatgpt) }
        await startGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        startGate.open()
        await switching.value

        #expect(harness.chatgpt.timesConversationEnded == 1)
        #expect(harness.output.providerChanges.isEmpty)
        #expect(harness.output.offerClearCount == 0)
        #expect(await harness.flow.currentProvider == .claude)
        #expect(!harness.log.kinds.contains(.providerSwitched(from: .claude, to: .chatgpt)))
        #expect(logEndsWithStop(harness))
    }

    @Test func aFailedStartAfterStopShowsNothing() async throws {
        let harness = try await usageLimitedHarness(questions: ["first"])
        let startGate = TestGate()
        harness.chatgpt.holdNextStart(at: startGate)
        harness.chatgpt.failNextStart(with: .notSignedIn)

        let switching = Task { await harness.flow.switchProvider(to: .chatgpt) }
        await startGate.waitUntilReached()
        _ = await harness.flow.finish(summaryEnabled: false)
        startGate.open()
        await switching.value

        #expect(harness.output.notices.isEmpty)
    }

    @Test func aSwitchWhileAQuestionIsPendingIsRefusedAndLeavesTheConversationAlone() async throws {
        let harness = try await startedHarness(questions: ["first"])
        harness.claude.holdNextAnswer()
        let question = Task { await harness.askQuestion() }
        for _ in 0..<200 where harness.claude.askedTurns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }

        await harness.flow.switchProvider(to: .chatgpt)
        harness.claude.releaseHeldAnswer()
        _ = await question.value

        #expect(harness.chatgpt.starts.isEmpty)
        #expect(harness.claude.timesConversationEnded == 0)
        #expect(await harness.flow.currentProvider == .claude)
        #expect(harness.output.answers.count == 1)
    }

    @Test func aQuestionKeyWhileTheSwitchRunsIsIgnored() async throws {
        let harness = try await usageLimitedHarness(questions: ["first", "second"])
        let startGate = TestGate()
        harness.chatgpt.holdNextStart(at: startGate)

        let switching = Task { await harness.flow.switchProvider(to: .chatgpt) }
        await startGate.waitUntilReached()
        let outcome = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime))
        startGate.open()
        await switching.value

        #expect(outcome == .ignoredBecauseBusy)
    }

    @Test func aFailedSwitchKeepsTheOfferAndTheOldProviderAndCanBeTriedAgain() async throws {
        let harness = try await usageLimitedHarness(questions: ["first"])
        harness.chatgpt.failNextStart(with: .notSignedIn)

        await harness.flow.switchProvider(to: .chatgpt)

        #expect(harness.output.notices.last == "Sign in to ChatGPT in Settings")
        #expect(harness.output.offerClearCount == 0)
        #expect(harness.claude.timesConversationEnded == 0)
        #expect(await harness.flow.currentProvider == .claude)

        await harness.flow.switchProvider(to: .chatgpt)

        #expect(harness.chatgpt.starts.count == 2)
        #expect(await harness.flow.currentProvider == .chatgpt)
        #expect(harness.output.offerClearCount == 1)
    }
}
