import Testing
@testable import ClickyCore

@Suite("Growing answer bubble")
struct GrowingAnswerBubbleStateTests {
    @Test func firstTextShowsTheBubbleAndLaterTextUpdatesItInPlace() {
        var state = GrowingAnswerBubbleState()
        #expect(state.textReported("Your lease") == .show(text: "Your lease", showsCheckingLine: false))
        #expect(state.textReported("Your lease ends in May.") == .update(text: "Your lease ends in May.", showsCheckingLine: false))
    }

    @Test func sameTextAgainChangesNothing() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Hello there")
        #expect(state.textReported("Hello there") == .nothing)
    }

    @Test func checkingLineShowsAloneThenIsClearedByText() {
        var state = GrowingAnswerBubbleState()
        #expect(state.checkingLineReported() == .show(text: "", showsCheckingLine: true))
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.textReported("Found it.") == .update(text: "Found it.", showsCheckingLine: false))
    }

    @Test func checkingLineSitsUnderTextSoFar() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Let me look.")
        #expect(state.checkingLineReported() == .update(text: "Let me look.", showsCheckingLine: true))
    }

    @Test func dismissedBubbleComesBackOnlyWhenTheTextGrew() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("First finding.")
        state.userDismissed()
        #expect(state.textReported("First finding.") == .nothing)
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.textReported("First finding. And a later one.")
            == .show(text: "First finding. And a later one.", showsCheckingLine: false))
    }

    @Test func dismissedThenSameFinalAnswerStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("It is Tuesday.")
        state.userDismissed()
        #expect(state.finalAnswerReported("It is Tuesday.") == .nothing)
    }

    @Test func dismissedThenDifferentFinalAnswerShowsAgain() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("It is Tuesday.")
        state.userDismissed()
        #expect(state.finalAnswerReported("It is Tuesday, the 4th.") == .show(text: "It is Tuesday, the 4th.", showsCheckingLine: false))
    }

    @Test func finalAnswerWithNoStreamedTextShows() {
        var state = GrowingAnswerBubbleState()
        #expect(state.finalAnswerReported("Done.") == .show(text: "Done.", showsCheckingLine: false))
    }

    @Test func finalAnswerMatchingTheBubbleChangesNothingExceptClearingTheCheckingLine() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Done.")
        #expect(state.finalAnswerReported("Done.") == .nothing)
        _ = state.checkingLineReported()
        #expect(state.finalAnswerReported("Done.") == .update(text: "Done.", showsCheckingLine: false))
    }

    @Test func resetForgetsTheDismissal() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Hi there.")
        state.userDismissed()
        state.reset()
        #expect(state.textReported("Hi") == .show(text: "Hi", showsCheckingLine: false))
    }

    @Test func emptyTextShowsNothing() {
        var state = GrowingAnswerBubbleState()
        #expect(state.textReported("  ") == .nothing)
    }
}
