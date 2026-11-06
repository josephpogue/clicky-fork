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
