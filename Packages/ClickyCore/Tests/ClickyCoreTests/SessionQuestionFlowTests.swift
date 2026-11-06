import Foundation
import Testing
@testable import ClickyCore

@Suite("Session question flow")
struct SessionQuestionFlowTests {
    private func startedHarness(questions: [String], shots: [DisplayShot]? = nil) async throws -> FlowHarness {
        let harness = FlowHarness(questions: questions, screenShots: shots)
        try await harness.flow.begin()
        return harness
    }

    // MARK: Empty speech

    @Test func emptyTranscriptionSendsNoProviderCallAndLogsNoQuestion() async throws {
        let harness = try await startedHarness(questions: ["   "])

        await harness.askQuestion()

        #expect(harness.claude.askedTurns.isEmpty)
        #expect(harness.chatgpt.askedTurns.isEmpty)
        #expect(!harness.log.kinds.contains { if case .question = $0 { return true } else { return false } })
        #expect(harness.output.notices == ["Didn't catch that"])
        #expect(harness.output.phases.last == .idle)
    }

    // MARK: One answered question

    @Test func answeredQuestionIsLoggedShownAndPointed() async throws {
        // Image 1280x800 shown on a 1440x900 display: x 1180 * (1440 / 1280) = 1327.5,
        // y 40 * (900 / 800) = 45, flipped to a bottom-left origin: 900 - 45 = 855.
        let harness = try await startedHarness(questions: ["where is the save button"])
        harness.claude.script([.success("The Save button is at the top right. [POINT:1180,40:save button:screen1]")])

        await harness.askQuestion()

        #expect(harness.claude.askedTurns.count == 1)
        #expect(harness.claude.askedTurns[0].questionText == "where is the save button")
        #expect(harness.claude.askedModels == ["sonnet"])
        #expect(harness.output.questions == ["where is the save button"])
        #expect(harness.output.answers == [RecordingFlowOutput.Answer(
            spokenText: "The Save button is at the top right.", provider: .claude, model: "sonnet",
            secondsToAnswer: 2.5, pointLabel: "save button"
        )])
        #expect(harness.output.pointers == [RecordingFlowOutput.Pointer(
            globalPoint: CGPoint(x: 1327.5, y: 855),
            displayFrameInPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            label: "save button"
        )])
        let kinds = harness.log.kinds
        #expect(kinds.contains(.questionStarted))
        #expect(kinds.contains(.question(text: "where is the save button", shotGroupID: 101, earlierShotGroupIDs: [])))
        #expect(kinds.contains(.answer(
            text: "The Save button is at the top right. [POINT:1180,40:save button:screen1]",
            provider: .claude, model: "sonnet", secondsToAnswer: 2.5, pointLabel: "save button"
        )))
        #expect(harness.output.phases == [
            .listening, .transcribing, .waitingForAnswer(provider: .claude), .idle,
        ])
    }

    @Test func pointNoneFliesNowhereAndShowsNoLabel() async throws {
        let harness = try await startedHarness(questions: ["what is HTML"])
        harness.claude.script([.success("HTML is the skeleton of a web page. [POINT:none]")])

        await harness.askQuestion()

        #expect(harness.output.pointers.isEmpty)
        #expect(harness.output.answers.first?.pointLabel == nil)
        #expect(harness.output.answers.first?.spokenText == "HTML is the skeleton of a web page.")
    }

    // MARK: Fresh conversation after 15 turns

    @Test func theFifteenthAnsweredTurnMakesTheNextQuestionStartAFreshConversationWithARecap() async throws {
        let questions = (1...16).map { "question \($0)" }
        let harness = try await startedHarness(questions: questions)

        for _ in 1...15 { await harness.askQuestion() }
        // Fresh conversations start before the next question, not right after the 15th answer.
        #expect(harness.claude.starts.count == 1)
        #expect(harness.claude.starts[0].recap == nil)

        await harness.askQuestion()

        #expect(harness.claude.starts.count == 2)
        let recap = try #require(harness.claude.starts[1].recap)
        #expect(recap.hasPrefix("Recap of this session so far (screenshots not included):\n"))
        #expect(recap.contains("Q: question 15\nA: Answer 15."))
        #expect(recap.contains("Q: question 1\nA: Answer 1."))
        #expect(harness.claude.askedTurns.count == 16)
        #expect(harness.claude.askedTurns[15].questionText == "question 16")
        // The old conversation ended before the new one began.
        #expect(harness.claude.timesConversationEnded == 1)
    }

    // MARK: Usage limit and switching to ChatGPT

    @Test func usageLimitSetsTheOfferAndTheSwitchStartsChatGPTWithARecapOfEarlierQuestions() async throws {
        let harness = try await startedHarness(questions: ["how do I save", "and how do I print"])
        harness.claude.script([
            .success("Choose Save from the File menu. [POINT:none]"),
            .failure(.usageLimitReached(message: "You've hit your limit")),
        ])

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.output.offers.count == 1)
        #expect(harness.output.offers[0].message == "You've hit your limit")
        #expect(harness.output.offers[0].switchTo == .chatgpt)
        #expect(harness.log.kinds.contains(.answerFailed(
            message: "You've hit your limit", provider: .claude, model: "sonnet", usageLimitReached: true
        )))
        #expect(harness.output.phases.last == .idle)

        await harness.flow.switchProvider(to: .chatgpt)

        #expect(harness.chatgpt.starts.count == 1)
        #expect(harness.chatgpt.starts[0].model == "gpt-test")
        let recap = try #require(harness.chatgpt.starts[0].recap)
        #expect(recap.contains("Q: how do I save\nA: Choose Save from the File menu."))
        #expect(harness.output.offerClearCount == 1)
        #expect(harness.output.providerChanges.map(\.provider) == [.chatgpt])
        #expect(harness.log.kinds.contains(.providerSwitched(from: .claude, to: .chatgpt)))
        #expect(harness.claude.timesConversationEnded == 1)
        // Nothing is re-asked on its own.
        #expect(harness.chatgpt.askedTurns.isEmpty)
    }

    @Test func afterTheSwitchTheNextQuestionGoesToChatGPT() async throws {
        let harness = try await startedHarness(questions: ["first", "second"])
        harness.claude.script([.failure(.usageLimitReached(message: "limit"))])

        await harness.askQuestion()
        await harness.flow.switchProvider(to: .chatgpt)
        await harness.askQuestion()

        #expect(harness.claude.askedTurns.count == 1)
        #expect(harness.chatgpt.askedTurns.map(\.questionText) == ["second"])
        #expect(harness.chatgpt.askedModels == ["gpt-test"])
        #expect(harness.output.answers.last?.provider == .chatgpt)
    }

    // MARK: Other failures

    @Test func failuresShowPlainNotices() async throws {
        let harness = try await startedHarness(questions: ["a", "b", "c", "d"])
        harness.claude.script([
            .failure(.notSignedIn),
            .failure(.cliNotFound),
            .failure(.notSubscriptionLogin(detail: "ANTHROPIC_API_KEY")),
            .failure(.failed(message: "Claude took too long to answer.")),
        ])

        for _ in 1...4 { await harness.askQuestion() }

        #expect(harness.output.notices == [
            "Sign in to Claude in Settings",
            "Install Claude Code",
            "This app only uses a Claude subscription login",
            "Claude took too long to answer.",
        ])
        #expect(harness.output.offers.isEmpty)
        let failedLogLines = harness.log.kinds.filter { if case .answerFailed = $0 { return true } else { return false } }
        #expect(failedLogLines.count == 4)
        #expect(harness.output.phases.last == .idle)
    }

    @Test func chatGPTFailuresNameChatGPTAndCodex() {
        #expect(ProviderFailureNotice.text(for: .notSignedIn, provider: .chatgpt) == "Sign in to ChatGPT in Settings")
        #expect(ProviderFailureNotice.text(for: .cliNotFound, provider: .chatgpt) == "Install Codex")
        #expect(ProviderFailureNotice.text(for: .notSubscriptionLogin(detail: "x"), provider: .chatgpt)
            == "This app only uses a ChatGPT subscription login")
    }

    // MARK: A tap while an answer is pending

    @Test func aTapWhileWaitingEndsTheOldAnswerAndStartsListeningWithoutAskingAgain() async throws {
        let harness = try await startedHarness(questions: ["first", "second"])
        harness.claude.holdNextAnswer()

        let firstQuestion = Task { await harness.askQuestion() }
        for _ in 0..<200 where harness.claude.askedTurns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(harness.claude.askedTurns.count == 1)

        let tapWhileWaiting = await harness.flow.handle(.questionStarted(at: FlowHarness.startTime))
        harness.claude.releaseHeldAnswer()
        _ = await firstQuestion.value

        #expect(tapWhileWaiting == .accepted)
        #expect(harness.claude.stopRequestCount == 1)
        #expect(harness.claude.askedTurns.count == 1)
        #expect(harness.output.questions == ["first"])
        #expect(harness.output.phases.last == .listening)
    }

    // MARK: Stop

    @Test func stopWithTheSummaryOffMakesNoSummarizeCall() async throws {
        let harness = try await startedHarness(questions: ["one"])
        await harness.askQuestion()

        let summary = await harness.flow.finish(summaryEnabled: false)

        #expect(summary == nil)
        #expect(harness.claude.summaries.isEmpty)
        #expect(harness.claude.timesConversationEnded == 1)
        #expect(harness.log.kinds.last == .sessionStopped)
    }

    @Test func stopWithTheSummaryOnAsksOnceWithTheTimelineText() async throws {
        let harness = try await startedHarness(questions: ["one"])
        harness.claude.script([.success("Answer to one. [POINT:none]")])
        await harness.askQuestion()

        let summary = await harness.flow.finish(summaryEnabled: true)

        #expect(summary == "You asked about the Save button.")
        #expect(harness.claude.summaries.count == 1)
        #expect(harness.claude.summaries[0].instructions == SessionSummaryInput.instructions)
        #expect(harness.claude.summaries[0].model == "sonnet")
        #expect(harness.claude.summaries[0].text.contains("Question: \"one\""))
        #expect(harness.claude.summaries[0].text.contains("Answer: Answer to one."))
    }

    @Test func stopWithNoAnsweredQuestionMakesNoSummarizeCall() async throws {
        let harness = try await startedHarness(questions: [])

        let summary = await harness.flow.finish(summaryEnabled: true)

        #expect(summary == nil)
        #expect(harness.claude.summaries.isEmpty)
    }

    @Test func aFailedSummaryLeavesTheSummaryEmpty() async throws {
        let harness = try await startedHarness(questions: ["one"])
        await harness.askQuestion()
        harness.claude.setSummaryResult(.failure(.failed(message: "no")))

        let summary = await harness.flow.finish(summaryEnabled: true)

        #expect(summary == nil)
        #expect(harness.claude.timesConversationEnded == 1)
    }

    // MARK: Context

    @Test func theContextNoteHoldsWhatHappenedSinceThePreviousQuestionOnly() async throws {
        let harness = try await startedHarness(questions: ["first", "second"])
        let spokenAt = FlowHarness.startTime.addingTimeInterval(500)
        await harness.flow.noteEvent(SessionEvent(time: spokenAt, kind: .utterance(text: "I think this is wrong")))

        await harness.askQuestion()
        await harness.askQuestion()

        #expect(harness.claude.askedTurns[0].contextNote.contains("I think this is wrong"))
        #expect(harness.claude.askedTurns[1].contextNote == "")
    }

    @Test func aQuestionAboutAnEarlierMomentSendsThatViewToo() async throws {
        let harness = try await startedHarness(questions: ["what was on the screen 5 minutes ago"])
        // Group 7 is 300 s older than the question's own capture at start + 1000 s; the picker needs 5 minutes.
        let earlier = QuestionsFixtures.group(
            id: 7, capturedAt: FlowHarness.startTime.addingTimeInterval(700), appName: "Safari", windowTitle: "Docs"
        )
        await harness.flow.noteShotGroup(earlier)

        await harness.askQuestion()

        let turn = try #require(harness.claude.askedTurns.first)
        #expect(turn.images.count == 2)
        #expect(turn.images[1].label.contains("earlier view"))
        #expect(harness.log.kinds.contains(.question(
            text: "what was on the screen 5 minutes ago", shotGroupID: 101, earlierShotGroupIDs: [7]
        )))
    }
}
