import Testing
@testable import ClickyCore

@Suite("Growing answer chat message")
struct GrowingAnswerChatStateTests {
    private static let newerLine = "(Cut short by your next question.)"

    @Test func firstTextAppendsAndLaterTextReplaces() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        #expect(state.textReported(answerNumber: 1, text: "Your") == [.appendComingMessage(token: 1, text: "Your")])
        #expect(state.textReported(answerNumber: 1, text: "Your lease") == [.replaceComingText(token: 1, text: "Your lease")])
    }

    @Test func checkingTurnsOnAndTheNextTextTurnsItOff() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        #expect(state.checkingReported(answerNumber: 1) == [.setCheckingNotes(true)])
        #expect(state.checkingReported(answerNumber: 1) == [])
        #expect(state.textReported(answerNumber: 1, text: "Found it.")
            == [.setCheckingNotes(false), .appendComingMessage(token: 1, text: "Found it.")])
    }

    @Test func finalAnswerFinishesTheComingMessage() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Part")
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.finalAnswerReceived(answerNumber: 1, text: "Part and rest.")
            == [.setCheckingNotes(false), .finishComingMessage(token: 1, text: "Part and rest.")])
        #expect(!state.hasComingMessage)
    }

    @Test func finalAnswerWithNothingStreamedAppendsAsToday() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        #expect(state.finalAnswerReceived(answerNumber: 1, text: "Whole.") == [.appendFinishedMessage(text: "Whole.")])
    }

    @Test func cutShortBeforeListeningFinishesItsCardOnce() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Half an")
        #expect(state.cutShort(answerNumber: 1, visibleText: "Half an answer", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Half an answer\n" + Self.newerLine),
        ])
        #expect(!state.hasComingMessage)
        // The listening phase that follows finds nothing still coming.
        #expect(state.newQuestionListening() == [])
    }

    // Listening first, then the late cut.
    @Test func lateCutAfterListeningUpdatesTheSameCardAndAddsNoSecondOne() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Half an")
        #expect(state.newQuestionListening() == [
            .finishComingMessage(token: 1, text: "Half an\n" + Self.newerLine),
        ])
        #expect(state.cutShort(answerNumber: 1, visibleText: "Half an answer", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Half an answer\n" + Self.newerLine),
        ])
        // A repeated cut has nothing left to finish.
        #expect(state.cutShort(answerNumber: 1, visibleText: "Half an answer", reason: .newerQuestion) == [])
    }

    // Finding 1 state: the cut arrives after the new answer's first text.
    @Test func lateCutAfterTheNewAnswersFirstTextNeverTouchesTheNewCard() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Old part")
        _ = state.newQuestionListening()
        _ = state.beginAnswer(answerNumber: 2)
        #expect(state.textReported(answerNumber: 2, text: "New") == [.appendComingMessage(token: 2, text: "New")])
        #expect(state.cutShort(answerNumber: 1, visibleText: "Old part", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Old part\n" + Self.newerLine),
        ])
        #expect(state.hasComingMessage)
        #expect(state.textReported(answerNumber: 2, text: "New answer") == [.replaceComingText(token: 2, text: "New answer")])
    }

    @Test func lateCutWithNoTextEverStreamedAddsNoCard() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        #expect(state.newQuestionListening() == [])
        _ = state.beginAnswer(answerNumber: 2)
        _ = state.textReported(answerNumber: 2, text: "New")
        #expect(state.cutShort(answerNumber: 1, visibleText: "", reason: .newerQuestion) == [])
        #expect(state.hasComingMessage)
        #expect(state.textReported(answerNumber: 2, text: "New one") == [.replaceComingText(token: 2, text: "New one")])
    }

    // Finding 1 state: a retired answer that never reports, then one that does. The order pairing used to put the
    // second answer's cut on the first answer's card.
    @Test func retiredAnswerThatNeverReportsDoesNotShiftTheNextCut() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "First")
        _ = state.newQuestionListening()            // answer 1 retired, its cut never arrives
        _ = state.beginAnswer(answerNumber: 2)
        _ = state.textReported(answerNumber: 2, text: "Second")
        _ = state.newQuestionListening()            // answer 2 retired
        _ = state.beginAnswer(answerNumber: 3)
        #expect(state.cutShort(answerNumber: 2, visibleText: "Second text", reason: .newerQuestion) == [
            .finishComingMessage(token: 2, text: "Second text\n" + Self.newerLine),
        ])
    }

    @Test func twoQuickNewQuestionsEachLateCutFindsItsOwnAnswer() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "First")
        _ = state.newQuestionListening()
        _ = state.beginAnswer(answerNumber: 2)      // second question, never streams
        _ = state.newQuestionListening()            // third question starts listening
        _ = state.beginAnswer(answerNumber: 3)
        _ = state.textReported(answerNumber: 3, text: "Third")
        #expect(state.cutShort(answerNumber: 1, visibleText: "First", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "First\n" + Self.newerLine),
        ])
        #expect(state.cutShort(answerNumber: 2, visibleText: "", reason: .newerQuestion) == [])
        #expect(state.hasComingMessage)
        #expect(state.comingText == "Third")
    }

    @Test func cutForAnUnknownNumberChangesNothing() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 4)
        _ = state.textReported(answerNumber: 4, text: "Going")
        #expect(state.cutShort(answerNumber: 9, visibleText: "Other", reason: .newerQuestion) == [])
        #expect(state.hasComingMessage)
        #expect(state.comingText == "Going")
    }

    @Test func reportsForANumberThatIsNotCurrentAreDropped() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Old")
        _ = state.newQuestionListening()
        _ = state.beginAnswer(answerNumber: 2)
        #expect(!state.isCurrent(answerNumber: 1))
        #expect(state.isCurrent(answerNumber: 2))
        #expect(state.textReported(answerNumber: 1, text: "Old more") == [])
        #expect(state.checkingReported(answerNumber: 1) == [])
        #expect(state.finalAnswerReceived(answerNumber: 1, text: "Old done.") == [])
        // The new answer is untouched.
        #expect(!state.hasComingMessage)
        #expect(state.textReported(answerNumber: 2, text: "New") == [.appendComingMessage(token: 2, text: "New")])
    }

    @Test func aFinishedAnswerDropsItsOwnLateReports() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.finalAnswerReceived(answerNumber: 1, text: "Done.")
        #expect(state.textReported(answerNumber: 1, text: "Late") == [])
        #expect(state.finalAnswerReceived(answerNumber: 1, text: "Done.") == [])
    }

    @Test func completedAfterNewerQuestionReplacesTheCardTextWithNoLine() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "The port is")
        _ = state.newQuestionListening()
        _ = state.beginAnswer(answerNumber: 2)
        #expect(state.cutShort(
            answerNumber: 1, visibleText: "The port is 8080.", reason: .completedAfterNewerQuestion) == [
            .finishComingMessage(token: 1, text: "The port is 8080."),
        ])
        #expect(state.cutShort(
            answerNumber: 1, visibleText: "The port is 8080.", reason: .completedAfterNewerQuestion) == [])
    }

    @Test func cutWithEmptyTextKeepsTheCardsOwnTextAndAddsTheLineOnce() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Card text")
        _ = state.newQuestionListening()
        _ = state.beginAnswer(answerNumber: 2)
        #expect(state.cutShort(answerNumber: 1, visibleText: "", reason: .newerQuestion) == [
            .finishComingMessage(token: 1, text: "Card text\n" + Self.newerLine),
        ])
        #expect(state.cutShort(answerNumber: 1, visibleText: "", reason: .newerQuestion) == [])
    }

    @Test func retiredNumbersOlderThanTheLastTenAreForgotten() {
        var state = GrowingAnswerChatState()
        for number in 1...12 {
            _ = state.beginAnswer(answerNumber: number)
            _ = state.textReported(answerNumber: number, text: "Answer \(number)")
        }
        _ = state.newQuestionListening()           // 12 retired: numbers 3 to 12 stay, 1 and 2 are forgotten
        #expect(state.cutShort(answerNumber: 1, visibleText: "Answer 1", reason: .newerQuestion) == [])
        #expect(state.cutShort(answerNumber: 2, visibleText: "Answer 2", reason: .newerQuestion) == [])
        #expect(state.cutShort(answerNumber: 3, visibleText: "Answer 3", reason: .newerQuestion) == [
            .finishComingMessage(token: 3, text: "Answer 3\n" + Self.newerLine),
        ])
    }

    @Test func listeningWithNothingInFlightDoesNothing() {
        var state = GrowingAnswerChatState()
        #expect(state.newQuestionListening() == [])
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.finalAnswerReceived(answerNumber: 1, text: "Done.")
        #expect(state.newQuestionListening() == [])
    }

    @Test func listeningClearsTheCheckingLine() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.newQuestionListening() == [.setCheckingNotes(false)])
    }

    // Failure partway.
    @Test func failedCutFinishesWithTheShortLineAndClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Going")
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.cutShort(answerNumber: 1, visibleText: "Going", reason: .failed) == [
            .setCheckingNotes(false), .finishComingMessage(token: 1, text: "Going\n(Cut short.)"),
        ])
        // The next question does not relabel it.
        #expect(state.newQuestionListening() == [])
    }

    @Test func failedBeforeAnyTextAddsNoCard() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        #expect(state.cutShort(answerNumber: 1, visibleText: "", reason: .failed) == [])
        #expect(state.cutShort(answerNumber: 1, visibleText: "", reason: .failed) == [])
    }

    @Test func aNoticeFinishesAStillComingMessageAndClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Going")
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.noticeShown() == [
            .setCheckingNotes(false), .finishComingMessage(token: 1, text: "Going\n(Cut short.)"),
        ])
        #expect(state.noticeShown() == [])
        #expect(state.newQuestionListening() == [])
    }

    @Test func aNoticeBeforeAnyTextOnlyClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.noticeShown() == [.setCheckingNotes(false)])
    }

    @Test func aNoticeAfterTheFailedCutChangesNothing() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Going")
        _ = state.cutShort(answerNumber: 1, visibleText: "Going", reason: .failed)
        #expect(state.noticeShown() == [])
    }

    // Stop.
    @Test func stopFinishesAComingMessageAsStoppedAndLateStoppedCutAddsNothingNew() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Going")
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.abandon(reason: .stopped) == [
            .setCheckingNotes(false), .finishComingMessage(token: 1, text: "Going\n(Stopped.)"),
        ])
        #expect(state.abandon(reason: .stopped) == [])
        #expect(state.cutShort(answerNumber: 1, visibleText: "Going", reason: .stopped) == [
            .finishComingMessage(token: 1, text: "Going\n(Stopped.)"),
        ])
        #expect(state.cutShort(answerNumber: 1, visibleText: "Going", reason: .stopped) == [])
    }

    @Test func abandonWithOnlyTheCheckingLineClearsIt() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.checkingReported(answerNumber: 1)
        #expect(state.abandon(reason: .stopped) == [.setCheckingNotes(false)])
    }

    @Test func resetForgetsEverything() {
        var state = GrowingAnswerChatState()
        _ = state.beginAnswer(answerNumber: 1)
        _ = state.textReported(answerNumber: 1, text: "Going")
        _ = state.newQuestionListening()
        state.reset()
        #expect(!state.hasComingMessage)
        #expect(state.cutShort(answerNumber: 1, visibleText: "Going", reason: .newerQuestion) == [])
    }
}
