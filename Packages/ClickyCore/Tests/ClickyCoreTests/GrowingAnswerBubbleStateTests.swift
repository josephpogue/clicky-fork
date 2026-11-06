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

    // Finding 5: a click during streaming must not flash back within a token.
    @Test func clickThenMoreTextWithNoToolCallStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("First finding.")
        state.userDismissed()
        #expect(state.textReported("First finding.") == .nothing)
        #expect(state.textReported("First finding. And") == .nothing)
        #expect(state.textReported("First finding. And more.") == .nothing)
        #expect(state.checkingLineReported() == .nothing)
    }

    @Test func clickThenToolCallThenNewTextShowsOnce() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("First finding.")
        state.userDismissed()
        state.toolCallStartedReported()
        // The tool call alone shows nothing; text before new findings arrive stays hidden until it differs.
        #expect(state.textReported("First finding. Second.")
            == .show(text: "First finding. Second.", showsCheckingLine: false))
        #expect(state.textReported("First finding. Second. Third") == .update(text: "First finding. Second. Third", showsCheckingLine: false))
    }

    @Test func clickThenCheckingLineThenNewTextShowsAgain() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("First finding.")
        state.userDismissed()
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.textReported("First finding. Later.")
            == .show(text: "First finding. Later.", showsCheckingLine: false))
    }

    @Test func clickTwiceNeedsAFreshToolCallEachTime() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("One.")
        state.userDismissed()
        state.userDismissed()
        state.toolCallStartedReported()
        _ = state.textReported("One. Two.")
        state.userDismissed()
        #expect(state.textReported("One. Two. Three.") == .nothing)
        state.toolCallStartedReported()
        #expect(state.textReported("One. Two. Three. Four.")
            == .show(text: "One. Two. Three. Four.", showsCheckingLine: false))
    }

    @Test func clickThenMoreTextThenDifferentFinalOnAPlainAnswerStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("One.")
        state.userDismissed()
        _ = state.textReported("One. Two.")
        #expect(state.finalAnswerReported("One. Two. Three.") == .nothing)
    }

    @Test func dismissedThenSameFinalAnswerStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("It is Tuesday.")
        state.userDismissed()
        #expect(state.finalAnswerReported("It is Tuesday.") == .nothing)
    }

    @Test func dismissedThenDifferentFinalAnswerWithNoNewFindingStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("It is Tuesday.")
        state.userDismissed()
        #expect(state.finalAnswerReported("It is Tuesday, the 4th.") == .nothing)
    }

    @Test func dismissedThenToolCallThenDifferentFinalShowsAgain() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("It is Tuesday.")
        state.userDismissed()
        state.toolCallStartedReported()
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

    // Wave 2 finding 4: a click on a bubble that held only "Checking your notes".
    @Test func clickOnTheCheckingOnlyBubbleThenFirstTextReshowsOnceAndGrowthUpdatesInPlace() {
        var state = GrowingAnswerBubbleState()
        #expect(state.checkingLineReported() == .show(text: "", showsCheckingLine: true))
        state.userDismissed()
        #expect(state.textReported("Found it") == .show(text: "Found it", showsCheckingLine: false))
        #expect(state.textReported("Found it in May.") == .update(text: "Found it in May.", showsCheckingLine: false))
    }

    @Test func clickOnTheCheckingOnlyBubbleThenNoTextStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.finalAnswerReported("   ") == .nothing)
    }

    @Test func clickOnTextWithTheCheckingLineReshowsAtTheNextDifferingText() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Let me look.")
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.textReported("Let me look.") == .nothing)
        #expect(state.textReported("Let me look. Found it.")
            == .show(text: "Let me look. Found it.", showsCheckingLine: false))
    }

    // Wave 3 V4: when a dismissed bubble comes back, one row per scenario, each from a fresh state.
    @Test func row1_plainStreamClickMoreTextFinal_hiddenThroughout() {
        var state = GrowingAnswerBubbleState()
        #expect(state.textReported("It is") == .show(text: "It is", showsCheckingLine: false))
        state.userDismissed()
        #expect(state.textReported("It is Tuesday") == .nothing)
        #expect(state.finalAnswerReported("It is Tuesday.") == .nothing)
    }

    @Test func row2_plainStreamClickToolCallFindingFinal_reshowsAtTheFinding() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Let me check.")
        state.userDismissed()
        state.toolCallStartedReported()
        #expect(state.textReported("Let me check. Your lease ends May 1.")
            == .show(text: "Let me check. Your lease ends May 1.", showsCheckingLine: false))
        #expect(state.finalAnswerReported("Let me check. Your lease ends May 1.") == .nothing)
    }

    @Test func row3_checkingLineOnlyClickFindingText_reshows() {
        var state = GrowingAnswerBubbleState()
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.textReported("Your lease ends May 1.")
            == .show(text: "Your lease ends May 1.", showsCheckingLine: false))
    }

    @Test func row4_textPlusCheckingLineClickFindingText_reshows() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Let me check.")
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.textReported("Let me check. Your lease ends May 1.")
            == .show(text: "Let me check. Your lease ends May 1.", showsCheckingLine: false))
    }

    @Test func row5_textPlusCheckingLineClickFinalWithTheSameText_staysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Let me check.")
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.finalAnswerReported("Let me check.") == .nothing)
    }

    @Test func row6_noClick_showsEveryStepAndTheFinalShowsTheFirstLines() {
        var state = GrowingAnswerBubbleState()
        #expect(state.textReported("Let me") == .show(text: "Let me", showsCheckingLine: false))
        #expect(state.textReported("Let me check.") == .update(text: "Let me check.", showsCheckingLine: false))
        #expect(state.checkingLineReported() == .update(text: "Let me check.", showsCheckingLine: true))
        #expect(state.textReported("Let me check. Found it.")
            == .update(text: "Let me check. Found it.", showsCheckingLine: false))
        #expect(state.finalAnswerReported("Let me check. Found it.") == .nothing)
        #expect(state.finalAnswerReported("Found it.") == .update(text: "Found it.", showsCheckingLine: false))
    }

    @Test func row7_clickThenANewQuestion_showsTheNewAnswer() {
        var state = GrowingAnswerBubbleState()
        _ = state.textReported("Old answer.")
        state.userDismissed()
        state.reset()
        #expect(state.textReported("New") == .show(text: "New", showsCheckingLine: false))
    }
}
