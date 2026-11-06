import Testing
@testable import ClickyCore

@Suite("Growing answer chat message")
struct GrowingAnswerChatStateTests {
    private static let newerLine = "(Cut short by your next question.)"

    @Test func firstTextAppendsAndLaterTextReplaces() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        #expect(state.textReported("Your") == [.appendComingMessage(token: 1, text: "Your")])
        #expect(state.textReported("Your lease") == [.replaceComingText(token: 1, text: "Your lease")])
    }

    @Test func checkingTurnsOnAndTheNextTextTurnsItOff() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        #expect(state.checkingReported() == [.setCheckingNotes(true)])
        #expect(state.checkingReported() == [])
        #expect(state.textReported("Found it.") == [.setCheckingNotes(false), .appendComingMessage(token: 1, text: "Found it.")])
    }

    @Test func finalAnswerFinishesTheComingMessage() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Part")
        _ = state.checkingReported()
        #expect(state.finalAnswerReceived("Part and rest.") == [.setCheckingNotes(false), .finishComingMessage(token: 1, text: "Part and rest.")])
        #expect(!state.hasComingMessage)
    }

    @Test func finalAnswerWithNothingStreamedAppendsAsToday() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        #expect(state.finalAnswerReceived("Whole.") == [.appendFinishedMessage(text: "Whole.")])
    }

    @Test func cutShortBeforeListeningFinishesItsCardOnce() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Half an")
        #expect(state.cutShort(visibleText: "Half an answer", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Half an answer\n" + Self.newerLine),
        ])
        #expect(!state.hasComingMessage)
        // The listening phase that follows finds nothing still coming.
        #expect(state.newQuestionListening() == [])
    }

    // Finding 1: listening first, then the late cut.
    @Test func lateCutAfterListeningUpdatesTheSameCardAndAddsNoSecondOne() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Half an")
        #expect(state.newQuestionListening() == [
            .finishComingMessage(token: 1, text: "Half an\n" + Self.newerLine),
        ])
        #expect(state.cutShort(visibleText: "Half an answer", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Half an answer\n" + Self.newerLine),
        ])
        // A repeated cut has nothing left to finish.
        #expect(state.cutShort(visibleText: "Half an answer", reason: .newerQuestion) == [])
    }

    @Test func lateCutAfterTheNewAnswersFirstTextNeverTouchesTheNewCard() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Old part")
        _ = state.newQuestionListening()
        _ = state.beginAnswer()
        #expect(state.textReported("New") == [.appendComingMessage(token: 2, text: "New")])
        #expect(state.cutShort(visibleText: "Old part", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Old part\n" + Self.newerLine),
        ])
        #expect(state.hasComingMessage)
        #expect(state.textReported("New answer") == [.replaceComingText(token: 2, text: "New answer")])
    }

    @Test func lateCutWithNoTextEverStreamedAddsNoCard() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        #expect(state.newQuestionListening() == [])
        _ = state.beginAnswer()
        _ = state.textReported("New")
        #expect(state.cutShort(visibleText: "", reason: .newerQuestion) == [])
        #expect(state.hasComingMessage)
        #expect(state.textReported("New one") == [.replaceComingText(token: 2, text: "New one")])
    }

    @Test func twoQuickNewQuestionsEachLateCutFindsItsOwnAnswer() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("First")
        _ = state.newQuestionListening()
        _ = state.beginAnswer()                      // second question, never streams
        _ = state.newQuestionListening()             // third question starts listening
        _ = state.beginAnswer()
        _ = state.textReported("Third")
        #expect(state.cutShort(visibleText: "First", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "First\n" + Self.newerLine),
        ])
        #expect(state.cutShort(visibleText: "", reason: .newerQuestion) == [])
        #expect(state.hasComingMessage)
        #expect(state.comingText == "Third")
    }

    @Test func listeningWithNothingInFlightDoesNothing() {
        var state = GrowingAnswerChatState()
        #expect(state.newQuestionListening() == [])
        _ = state.beginAnswer()
        _ = state.finalAnswerReceived("Done.")
        #expect(state.newQuestionListening() == [])
    }

    @Test func listeningClearsTheCheckingLine() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.checkingReported()
        #expect(state.newQuestionListening() == [.setCheckingNotes(false)])
    }

    // Finding 2: failure partway.
    @Test func failedCutFinishesWithTheShortLineAndClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Going")
        _ = state.checkingReported()
        #expect(state.cutShort(visibleText: "Going", reason: .failed) == [
            .setCheckingNotes(false), .finishComingMessage(token: 1, text: "Going\n(Cut short.)"),
        ])
        // The next question does not relabel it.
        #expect(state.newQuestionListening() == [])
    }

    @Test func failedBeforeAnyTextAddsNoCard() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        #expect(state.cutShort(visibleText: "", reason: .failed) == [])
        #expect(state.cutShort(visibleText: "", reason: .failed) == [])
    }

    @Test func aNoticeFinishesAStillComingMessageAndClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Going")
        _ = state.checkingReported()
        #expect(state.noticeShown() == [
            .setCheckingNotes(false), .finishComingMessage(token: 1, text: "Going\n(Cut short.)"),
        ])
        #expect(state.noticeShown() == [])
        #expect(state.newQuestionListening() == [])
    }

    @Test func aNoticeBeforeAnyTextOnlyClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.checkingReported()
        #expect(state.noticeShown() == [.setCheckingNotes(false)])
    }

    @Test func aNoticeAfterTheFailedCutChangesNothing() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Going")
        _ = state.cutShort(visibleText: "Going", reason: .failed)
        #expect(state.noticeShown() == [])
    }

    // Finding 6: Stop.
    @Test func stopFinishesAComingMessageAsStoppedAndLateStoppedCutAddsNothingNew() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Going")
        _ = state.checkingReported()
        #expect(state.abandon(reason: .stopped) == [
            .setCheckingNotes(false), .finishComingMessage(token: 1, text: "Going\n(Stopped.)"),
        ])
        #expect(state.abandon(reason: .stopped) == [])
        #expect(state.cutShort(visibleText: "Going", reason: .stopped) == [
            .finishComingMessage(token: 1, text: "Going\n(Stopped.)"),
        ])
        #expect(state.cutShort(visibleText: "Going", reason: .stopped) == [])
    }

    @Test func abandonWithOnlyTheCheckingLineClearsIt() {
        var state = GrowingAnswerChatState()
        _ = state.checkingReported()
        #expect(state.abandon(reason: .stopped) == [.setCheckingNotes(false)])
    }

    @Test func resetForgetsEverything() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer()
        _ = state.textReported("Going")
        _ = state.newQuestionListening()
        state.reset()
        #expect(!state.hasComingMessage)
        #expect(state.cutShort(visibleText: "", reason: .newerQuestion) == [])
    }
}
