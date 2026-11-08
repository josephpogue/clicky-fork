import Testing
@testable import ClickyCore

@Suite("Growing answer bubble")
struct GrowingAnswerBubbleStateTests {
    private func line(_ text: String, hasMore: Bool = false) -> CursorLine {
        CursorLine(text: text, hasMoreInChat: hasMore)
    }

    @Test func aFooterAloneLineIsShowable() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("", hasMore: true)) == .show(line: line("", hasMore: true), showsCheckingLine: false))
        #expect(state.checkingLineReported() == .update(line: line("", hasMore: true), showsCheckingLine: true))
    }

    @Test func aLineWithNoTextAndNoFooterShowsNothing() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("")) == .nothing)
    }

    @Test func theFooterAppearingOnTheSameTextUpdatesInPlace() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Done."))
        #expect(state.lineReported(line("Done.", hasMore: true)) == .update(line: line("Done.", hasMore: true), showsCheckingLine: false))
    }

    @Test func firstTextShowsTheBubbleAndLaterTextUpdatesItInPlace() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("Your lease")) == .show(line: line("Your lease"), showsCheckingLine: false))
        #expect(state.lineReported(line("Your lease ends in May.")) == .update(line: line("Your lease ends in May."), showsCheckingLine: false))
    }

    @Test func sameTextAgainChangesNothing() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Hello there"))
        #expect(state.lineReported(line("Hello there")) == .nothing)
    }

    @Test func checkingLineShowsAloneThenIsClearedByText() {
        var state = GrowingAnswerBubbleState()
        #expect(state.checkingLineReported() == .show(line: line(""), showsCheckingLine: true))
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.lineReported(line("Found it.")) == .update(line: line("Found it."), showsCheckingLine: false))
    }

    @Test func checkingLineSitsUnderTextSoFar() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Let me look."))
        #expect(state.checkingLineReported() == .update(line: line("Let me look."), showsCheckingLine: true))
    }

    // Finding 5: a click during streaming must not flash back within a token.
    @Test func clickThenMoreTextWithNoToolCallStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("First finding."))
        state.userDismissed()
        #expect(state.lineReported(line("First finding.")) == .nothing)
        #expect(state.lineReported(line("First finding. And")) == .nothing)
        #expect(state.lineReported(line("First finding. And more.")) == .nothing)
        #expect(state.checkingLineReported() == .nothing)
    }

    @Test func clickThenToolCallThenNewTextShowsOnce() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("First finding."))
        state.userDismissed()
        state.toolCallStartedReported()
        // The tool call alone shows nothing; text before new findings arrive stays hidden until it differs.
        #expect(state.lineReported(line("First finding. Second."))
            == .show(line: line("First finding. Second."), showsCheckingLine: false))
        #expect(state.lineReported(line("First finding. Second. Third")) == .update(line: line("First finding. Second. Third"), showsCheckingLine: false))
    }

    @Test func clickThenCheckingLineThenNewTextShowsAgain() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("First finding."))
        state.userDismissed()
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.lineReported(line("First finding. Later."))
            == .show(line: line("First finding. Later."), showsCheckingLine: false))
    }

    @Test func clickTwiceNeedsAFreshToolCallEachTime() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("One."))
        state.userDismissed()
        state.userDismissed()
        state.toolCallStartedReported()
        _ = state.lineReported(line("One. Two."))
        state.userDismissed()
        #expect(state.lineReported(line("One. Two. Three.")) == .nothing)
        state.toolCallStartedReported()
        #expect(state.lineReported(line("One. Two. Three. Four."))
            == .show(line: line("One. Two. Three. Four."), showsCheckingLine: false))
    }

    @Test func clickThenMoreTextThenDifferentFinalOnAPlainAnswerStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("One."))
        state.userDismissed()
        _ = state.lineReported(line("One. Two."))
        #expect(state.lineReported(line("One. Two. Three.")) == .nothing)
    }

    @Test func dismissedThenSameFinalAnswerStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("It is Tuesday."))
        state.userDismissed()
        #expect(state.lineReported(line("It is Tuesday.")) == .nothing)
    }

    @Test func dismissedThenDifferentFinalAnswerWithNoNewFindingStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("It is Tuesday."))
        state.userDismissed()
        #expect(state.lineReported(line("It is Tuesday, the 4th.")) == .nothing)
    }

    @Test func dismissedThenToolCallThenDifferentFinalShowsAgain() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("It is Tuesday."))
        state.userDismissed()
        state.toolCallStartedReported()
        #expect(state.lineReported(line("It is Tuesday, the 4th.")) == .show(line: line("It is Tuesday, the 4th."), showsCheckingLine: false))
    }

    @Test func finalAnswerWithNoStreamedTextShows() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("Done.")) == .show(line: line("Done."), showsCheckingLine: false))
    }

    @Test func finalAnswerMatchingTheBubbleChangesNothingExceptClearingTheCheckingLine() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Done."))
        #expect(state.lineReported(line("Done.")) == .nothing)
        _ = state.checkingLineReported()
        #expect(state.lineReported(line("Done.")) == .update(line: line("Done."), showsCheckingLine: false))
    }

    @Test func resetForgetsTheDismissal() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Hi there."))
        state.userDismissed()
        state.reset()
        #expect(state.lineReported(line("Hi")) == .show(line: line("Hi"), showsCheckingLine: false))
    }

    @Test func emptyTextShowsNothing() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("  ")) == .nothing)
    }

    // Wave 2 finding 4: a click on a bubble that held only "Checking your notes".
    @Test func clickOnTheCheckingOnlyBubbleThenFirstTextReshowsOnceAndGrowthUpdatesInPlace() {
        var state = GrowingAnswerBubbleState()
        #expect(state.checkingLineReported() == .show(line: line(""), showsCheckingLine: true))
        state.userDismissed()
        #expect(state.lineReported(line("Found it")) == .show(line: line("Found it"), showsCheckingLine: false))
        #expect(state.lineReported(line("Found it in May.")) == .update(line: line("Found it in May."), showsCheckingLine: false))
    }

    @Test func clickOnTheCheckingOnlyBubbleThenNoTextStaysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.checkingLineReported() == .nothing)
        #expect(state.lineReported(line("   ")) == .nothing)
    }

    @Test func clickOnTextWithTheCheckingLineReshowsAtTheNextDifferingText() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Let me look."))
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.lineReported(line("Let me look.")) == .nothing)
        #expect(state.lineReported(line("Let me look. Found it."))
            == .show(line: line("Let me look. Found it."), showsCheckingLine: false))
    }

    // Wave 3 V4: when a dismissed bubble comes back, one row per scenario, each from a fresh state.
    @Test func row1_plainStreamClickMoreTextFinal_hiddenThroughout() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("It is")) == .show(line: line("It is"), showsCheckingLine: false))
        state.userDismissed()
        #expect(state.lineReported(line("It is Tuesday")) == .nothing)
        #expect(state.lineReported(line("It is Tuesday.")) == .nothing)
    }

    @Test func row2_plainStreamClickToolCallFindingFinal_reshowsAtTheFinding() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Let me check."))
        state.userDismissed()
        state.toolCallStartedReported()
        #expect(state.lineReported(line("Let me check. Your lease ends May 1."))
            == .show(line: line("Let me check. Your lease ends May 1."), showsCheckingLine: false))
        #expect(state.lineReported(line("Let me check. Your lease ends May 1.")) == .nothing)
    }

    @Test func row3_checkingLineOnlyClickFindingText_reshows() {
        var state = GrowingAnswerBubbleState()
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.lineReported(line("Your lease ends May 1."))
            == .show(line: line("Your lease ends May 1."), showsCheckingLine: false))
    }

    @Test func row4_textPlusCheckingLineClickFindingText_reshows() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Let me check."))
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.lineReported(line("Let me check. Your lease ends May 1."))
            == .show(line: line("Let me check. Your lease ends May 1."), showsCheckingLine: false))
    }

    @Test func row5_textPlusCheckingLineClickFinalWithTheSameText_staysHidden() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Let me check."))
        _ = state.checkingLineReported()
        state.userDismissed()
        #expect(state.lineReported(line("Let me check.")) == .nothing)
    }

    @Test func row6_noClick_showsEveryStepAndTheFinalShowsTheFirstLines() {
        var state = GrowingAnswerBubbleState()
        #expect(state.lineReported(line("Let me")) == .show(line: line("Let me"), showsCheckingLine: false))
        #expect(state.lineReported(line("Let me check.")) == .update(line: line("Let me check."), showsCheckingLine: false))
        #expect(state.checkingLineReported() == .update(line: line("Let me check."), showsCheckingLine: true))
        #expect(state.lineReported(line("Let me check. Found it."))
            == .update(line: line("Let me check. Found it."), showsCheckingLine: false))
        #expect(state.lineReported(line("Let me check. Found it.")) == .nothing)
        #expect(state.lineReported(line("Found it.")) == .update(line: line("Found it."), showsCheckingLine: false))
    }

    @Test func row7_clickThenANewQuestion_showsTheNewAnswer() {
        var state = GrowingAnswerBubbleState()
        _ = state.lineReported(line("Old answer."))
        state.userDismissed()
        state.reset()
        #expect(state.lineReported(line("New")) == .show(line: line("New"), showsCheckingLine: false))
    }
}
