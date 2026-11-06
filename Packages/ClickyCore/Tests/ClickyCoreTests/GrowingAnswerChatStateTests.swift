import Testing
@testable import ClickyCore

@Suite("Growing answer chat message")
struct GrowingAnswerChatStateTests {
    @Test func firstTextAppendsAndLaterTextReplaces() {
        var state = GrowingAnswerChatState()
        #expect(state.textReported("Your") == [.appendComingMessage(text: "Your")])
        #expect(state.textReported("Your lease") == [.replaceComingText(text: "Your lease")])
    }

    @Test func checkingTurnsOnAndTheNextTextTurnsItOff() {
        var state = GrowingAnswerChatState()
        #expect(state.checkingReported() == [.setCheckingNotes(true)])
        #expect(state.checkingReported() == [])
        #expect(state.textReported("Found it.") == [.setCheckingNotes(false), .appendComingMessage(text: "Found it.")])
    }

    @Test func finalAnswerFinishesTheComingMessage() {
        var state = GrowingAnswerChatState()
        _ = state.textReported("Part")
        _ = state.checkingReported()
        #expect(state.finalAnswerReceived("Part and rest.") == [.setCheckingNotes(false), .finishComingMessage(text: "Part and rest.")])
        #expect(!state.hasComingMessage)
    }

    @Test func finalAnswerWithNothingStreamedAppendsAsToday() {
        var state = GrowingAnswerChatState()
        #expect(state.finalAnswerReceived("Whole.") == [.appendFinishedMessage(text: "Whole.")])
    }

    @Test func cutShortFinishesWithTheLastLine() {
        var state = GrowingAnswerChatState()
        _ = state.textReported("Half an")
        #expect(state.cutShort(visibleText: "Half an answer") == [
            .finishComingMessage(text: "Half an answer\n(Cut short by your next question.)"),
        ])
        #expect(!state.hasComingMessage)
    }

    @Test func cutShortWithNothingStreamedAppendsTheTextAndTheLine() {
        var state = GrowingAnswerChatState()
        #expect(state.cutShort(visibleText: "Partial") == [
            .appendFinishedMessage(text: "Partial\n(Cut short by your next question.)"),
        ])
        #expect(state.cutShort(visibleText: "") == [])
    }

    @Test func abandonFinishesAComingMessageAsCutShortAndClearsChecking() {
        var state = GrowingAnswerChatState()
        _ = state.textReported("Going")
        _ = state.checkingReported()
        #expect(state.abandon() == [
            .setCheckingNotes(false),
            .finishComingMessage(text: "Going\n(Cut short by your next question.)"),
        ])
        #expect(state.abandon() == [])
    }

    @Test func abandonWithOnlyTheCheckingLineClearsIt() {
        var state = GrowingAnswerChatState()
        _ = state.checkingReported()
        #expect(state.abandon() == [.setCheckingNotes(false)])
    }

    @Test func cutShortThenListeningAbandonDoesNothingTwice() {
        var state = GrowingAnswerChatState()
        _ = state.textReported("Going")
        _ = state.cutShort(visibleText: "Going")
        #expect(state.abandon() == [])
    }
}
