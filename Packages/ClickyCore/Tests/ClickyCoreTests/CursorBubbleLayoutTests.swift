import CoreGraphics
import Testing
@testable import ClickyCore

/// Where the answer bubble sits beside the cursor, which corner is tight, and how wide and tall it is.
struct CursorBubbleLayoutTests {
    // AppKit global coordinates, origin bottom-left.
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let shortBubbleSize = CGSize(width: 300, height: 80)

    private func place(cursor: CGPoint, size: CGSize) -> CursorBubbleLayout.Placement {
        CursorBubbleLayout.placement(anchor: .cursor(at: cursor), bubbleSize: size, visibleFrame: visibleFrame)
    }

    @Test func defaultSpotIsBelowAndRightOfTheCursor() {
        let placement = place(cursor: CGPoint(x: 500, y: 600), size: shortBubbleSize)
        #expect(placement.origin == CGPoint(x: 518, y: 500))
        #expect(placement.nearCorner == .topLeading)
    }

    @Test func flipsLeftWhenTheRightEdgeWouldPassTheDisplay() {
        let placement = place(cursor: CGPoint(x: 1400, y: 600), size: shortBubbleSize)
        #expect(placement.origin == CGPoint(x: 1082, y: 500))
        #expect(placement.nearCorner == .topTrailing)
    }

    @Test func flipsUpWhenTheBottomWouldPassTheDisplay() {
        let placement = place(cursor: CGPoint(x: 500, y: 60), size: shortBubbleSize)
        #expect(placement.origin == CGPoint(x: 518, y: 68))
        #expect(placement.nearCorner == .bottomLeading)
    }

    @Test func flipsBothWaysInTheBottomRightCorner() {
        let placement = place(cursor: CGPoint(x: 1400, y: 60), size: shortBubbleSize)
        #expect(placement.origin == CGPoint(x: 1082, y: 68))
        #expect(placement.nearCorner == .bottomTrailing)
    }

    @Test func aTallBubbleFlipsUpEarlierThanAShortOne() {
        let placement = place(cursor: CGPoint(x: 500, y: 150), size: CGSize(width: 300, height: 197))
        #expect(placement.origin == CGPoint(x: 518, y: 158))
        #expect(placement.nearCorner == .bottomLeading)
    }

    @Test func clampsInsideTheVisibleFrameWhenNeitherSideFits() {
        // A cursor above the visible frame (in the menu bar): the bubble would pass the top, so it is held inside.
        let placement = place(cursor: CGPoint(x: 500, y: 1000), size: CGSize(width: 300, height: 197))
        #expect(placement.origin.y == 747.0)
    }

    @Test func ridesUnderThePointerLabelLeftAlignedWithASixPointGap() {
        // Label frame 110...190 x 853...875 (AppKit); the bubble's top sits 6 pt under its bottom edge.
        let labelFrame = CGRect(x: 110, y: 853, width: 80, height: 22)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(labelFrame),
            bubbleSize: CGSize(width: 280, height: 60),
            visibleFrame: visibleFrame)
        #expect(placement.origin == CGPoint(x: 110, y: 787.0))
        #expect(placement.nearCorner == .topLeading)
    }

    @Test func ridingBubbleFlipsLeftToRightAlignWithTheLabel() {
        let labelFrame = CGRect(x: 1400, y: 500, width: 80, height: 22)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(labelFrame),
            bubbleSize: CGSize(width: 300, height: 60),
            visibleFrame: visibleFrame)
        #expect(placement.origin.x == 1180.0)
        #expect(placement.nearCorner == .topTrailing)
    }

    @Test func ridingBubbleFlipsAboveTheLabelNearTheBottom() {
        let labelFrame = CGRect(x: 200, y: 40, width: 80, height: 22)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(labelFrame),
            bubbleSize: CGSize(width: 300, height: 60),
            visibleFrame: visibleFrame)
        #expect(placement.origin == CGPoint(x: 200, y: 68))
        #expect(placement.nearCorner == .bottomLeading)
    }

    @Test func pointerLabelFrameIsInGlobalCoordinates() {
        // Pointer at (100, 100) from the top-left of a 1512 x 982 display at the global origin; the label goes
        // right of it (10 gap) and 18 below its centre line.
        let labelFrame = CursorBubbleLayout.pointerLabelFrame(
            pointerPosition: CGPoint(x: 100, y: 100),
            labelSize: CGSize(width: 80, height: 22),
            fullLabelWidth: 80,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(labelFrame == CGRect(x: 110, y: 853, width: 80, height: 22))
    }

    // MARK: Text layout

    @Test func fiveLinesStayShortAndNotCut() {
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 5, naturalBodyHeightAtShortWidth: 100, naturalBodyHeightAtLongWidth: 90)
        #expect(layout.width == 300)
        #expect(layout.bodyHeight == 100)
        #expect(layout.isBodyCut == false)
    }

    @Test func sixLinesGoLongAtThreeHundredFortyAndStayWholeUnderTheCap() {
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 6, naturalBodyHeightAtShortWidth: 120, naturalBodyHeightAtLongWidth: 110)
        #expect(layout.width == 340)
        #expect(layout.bodyHeight == 110)
        #expect(layout.isBodyCut == false)
    }

    @Test func aBodyTallerThanTheCapIsCutAtOneHundredNinetySeven() {
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 14, naturalBodyHeightAtShortWidth: 280, naturalBodyHeightAtLongWidth: 250)
        #expect(layout.width == 340)
        #expect(layout.bodyHeight == 197)
        #expect(layout.isBodyCut == true)
    }

    @Test func aBodyExactlyAtTheCapIsNotCut() {
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 9, naturalBodyHeightAtShortWidth: 200, naturalBodyHeightAtLongWidth: 197)
        #expect(layout.isBodyCut == false)
        #expect(layout.bodyHeight == 197)
    }
}

/// The answer bubble while the answer is still coming: the newest lines past the cap, and the "Checking your notes" line.
struct CursorBubbleGrowingAnswerLayoutTests {
    /// One bubble line: 13.5 pt type at 145% leading.
    private let lineHeight: CGFloat = 13.5 * 1.45

    @Test func thirtyShortLinesInNewestLinesModeKeepTheLastLinesThatFitAndAreCutAtTheTop() {
        let naturalHeight = 30 * lineHeight
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 30,
            naturalBodyHeightAtShortWidth: naturalHeight,
            naturalBodyHeightAtLongWidth: naturalHeight,
            showsNewestLines: true)
        #expect(layout.width == 340)
        #expect(layout.bodyHeight == 197)
        #expect(layout.isBodyCut == true)
        #expect(layout.cutEdge == .top)
        // Everything above the last 197 pt is hidden: the body shows the newest lines.
        #expect(abs(layout.hiddenHeightAbove - (naturalHeight - 197)) < 0.001)
    }

    @Test func theSameTextWithoutNewestLinesIsCutAtTheBottomAsToday() {
        let naturalHeight = 30 * lineHeight
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 30,
            naturalBodyHeightAtShortWidth: naturalHeight,
            naturalBodyHeightAtLongWidth: naturalHeight)
        #expect(layout.cutEdge == .bottom)
        #expect(layout.hiddenHeightAbove == 0)
        #expect(layout.checkingLineExtraHeight == 0)
    }

    @Test func shortTextInNewestLinesModeIsUnchangedFromToday() {
        let growing = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 2, naturalBodyHeightAtShortWidth: 2 * lineHeight, naturalBodyHeightAtLongWidth: 2 * lineHeight,
            showsNewestLines: true)
        let today = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 2, naturalBodyHeightAtShortWidth: 2 * lineHeight, naturalBodyHeightAtLongWidth: 2 * lineHeight)
        #expect(growing == today)
        #expect(growing.width == 300)
        #expect(growing.cutEdge == .none)
        #expect(growing.isBodyCut == false)
    }

    @Test func theCheckingLineUnderTextAddsAFixedHeightAndLeavesTheBodyAlone() {
        let withoutLine = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 2, naturalBodyHeightAtShortWidth: 40, naturalBodyHeightAtLongWidth: 38)
        let withLine = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 2, naturalBodyHeightAtShortWidth: 40, naturalBodyHeightAtLongWidth: 38,
            showsCheckingLine: true)
        #expect(withLine.width == withoutLine.width)
        #expect(withLine.bodyHeight == withoutLine.bodyHeight)
        #expect(withLine.checkingLineExtraHeight == CursorBubbleLayout.checkingLineGap + CursorBubbleLayout.checkingLineHeight)
        #expect(withLine.contentHeight == CGFloat(40 + 8 + 18))
    }

    @Test func theCheckingLineAddsTheSameHeightUnderACutBody() {
        let naturalHeight = 30 * lineHeight
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 30, naturalBodyHeightAtShortWidth: naturalHeight, naturalBodyHeightAtLongWidth: naturalHeight,
            showsNewestLines: true, showsCheckingLine: true)
        #expect(layout.bodyHeight == 197)
        #expect(layout.contentHeight == CGFloat(197 + 8 + 18))
    }

    @Test func theCheckingLineAloneIsACompactBubbleWithNoBody() {
        let layout = CursorBubbleLayout.textLayout(
            lineCountAtShortWidth: 0, naturalBodyHeightAtShortWidth: 0, naturalBodyHeightAtLongWidth: 0,
            showsNewestLines: true, showsCheckingLine: true)
        #expect(layout.width == CursorBubbleLayout.checkingLineAloneWidth)
        #expect(layout.bodyHeight == 0)
        #expect(layout.cutEdge == .none)
        // Alone, there is no text above it, so no gap.
        #expect(layout.checkingLineExtraHeight == 18)
        #expect(layout.contentHeight == 18)
    }
}
