import CoreGraphics
import Testing
@testable import ClickyCore

/// A bubble riding under the pointer's label must never cover the pointer or the spot it points at,
/// and the display holding the cursor is picked the same way at every edge.
struct CursorBubbleClearanceTests {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let bubbleSize = CGSize(width: 300, height: 80)

    /// The label, pointer and clearance frame for a target, built the way the overlay does it: the pointer
    /// sits 8 pt right of and 12 pt below the target (AppKit: lower y), the label 10 pt right of the pointer
    /// and 18 pt below its centre.
    private func scene(target: CGPoint, screen: CGRect? = nil) -> (label: CGRect, clearance: CGRect, pointer: CGRect) {
        let screenFrame = screen ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pointerGlobal = CGPoint(x: target.x + 8, y: target.y - 12)
        let pointerPositionTopLeft = CGPoint(
            x: pointerGlobal.x - screenFrame.minX, y: screenFrame.maxY - pointerGlobal.y)
        let label = CursorBubbleLayout.pointerLabelFrame(
            pointerPosition: pointerPositionTopLeft,
            labelSize: CGSize(width: 80, height: 22),
            fullLabelWidth: 80,
            screenFrame: screenFrame)
        let clearance = CursorBubbleLayout.pointerClearanceFrame(
            pointerPosition: pointerPositionTopLeft, screenFrame: screenFrame, target: target, isPointerHoldingAtTarget: true)
        let pointer = CGRect(x: pointerGlobal.x - 8, y: pointerGlobal.y - 8, width: 16, height: 16)
        return (label, clearance, pointer)
    }

    private func bubbleFrame(_ target: CGPoint, screen: CGRect? = nil, visible: CGRect? = nil) -> (CGRect, CursorBubbleLayout.Placement, CGPoint, CGRect) {
        let s = scene(target: target, screen: screen)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(s.label, clearing: s.clearance),
            bubbleSize: bubbleSize,
            visibleFrame: visible ?? visibleFrame)
        return (CGRect(origin: placement.origin, size: bubbleSize), placement, target, s.pointer)
    }

    @Test func nearTheBottomEdgeTheFlippedBubbleClearsThePointerAndTheTarget() {
        let (bubble, placement, target, pointer) = bubbleFrame(CGPoint(x: 200, y: 60))
        #expect(placement.nearCorner == .bottomLeading)
        #expect(bubble.minY >= pointer.maxY + CursorBubbleLayout.gapBelowPointerLabel - 0.001)
        #expect(bubble.minY > target.y)
        #expect(!bubble.intersects(pointer))
        #expect(!bubble.contains(target))
    }

    @Test func nearTheRightEdgeTheFlippedLeftBubbleRightAlignsWithTheLabelAndLeavesTheTargetUncovered() {
        let (bubble, placement, target, pointer) = bubbleFrame(CGPoint(x: 1450, y: 600))
        let label = scene(target: target).label
        #expect(placement.nearCorner == .topTrailing)
        #expect(bubble.maxX == label.maxX)
        #expect(!bubble.contains(target))
        #expect(!bubble.intersects(pointer))
    }

    @Test func inTheBottomRightCornerBothFlipsClearThePointerAndTheTarget() {
        let (bubble, placement, target, pointer) = bubbleFrame(CGPoint(x: 1450, y: 60))
        let label = scene(target: target).label
        #expect(placement.nearCorner == .bottomTrailing)
        #expect(bubble.maxX == label.maxX)
        #expect(!bubble.contains(target))
        #expect(!bubble.intersects(pointer))
        #expect(bubble.minY > target.y)
    }

    @Test func nearTheTopEdgeTheBubbleStaysBelowTheLabelUnchanged() {
        let target = CGPoint(x: 400, y: 900)
        let s = scene(target: target)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(s.label, clearing: s.clearance), bubbleSize: bubbleSize, visibleFrame: visibleFrame)
        let withoutClearance = CursorBubbleLayout.placement(
            anchor: .belowLabel(s.label), bubbleSize: bubbleSize, visibleFrame: visibleFrame)
        #expect(placement == withoutClearance)
        #expect(placement.nearCorner == .topLeading)
        #expect(placement.origin.y + bubbleSize.height == s.label.minY - CursorBubbleLayout.gapBelowPointerLabel)
    }

    @Test func onADisplayWithANegativeOriginTheFlipUpStillClearsThePointerAndTheTarget() {
        // A second display to the left and one step down: global x from -1440, y from -300.
        let screen = CGRect(x: -1440, y: -300, width: 1440, height: 900)
        let visible = CGRect(x: -1440, y: -300, width: 1440, height: 875)
        let (bubble, placement, target, pointer) = bubbleFrame(CGPoint(x: -1200, y: -240), screen: screen, visible: visible)
        #expect(placement.nearCorner == .bottomLeading)
        #expect(!bubble.contains(target))
        #expect(!bubble.intersects(pointer))
        #expect(bubble.minY > target.y)
        #expect(visible.contains(bubble))
    }

    @Test func clearanceFrameHoldsThePointerAndTheTarget() {
        let frame = CursorBubbleLayout.pointerClearanceFrame(
            pointerPosition: CGPoint(x: 208, y: 782), screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), target: CGPoint(x: 200, y: 188 - 128),
            isPointerHoldingAtTarget: true)
        #expect(frame.contains(CGPoint(x: 208, y: 200)))
        #expect(frame.contains(CGPoint(x: 200, y: 60)))
    }

    // MARK: Which display holds the cursor

    private let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)

    @Test func aPointInsideADisplayPicksIt() {
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 1500, y: 400), in: [left, right]) == 1)
    }

    @Test func theTopPixelRowBelongsToTheDisplay() {
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 500, y: 800), in: [left, right]) == 0)
    }

    @Test func theRightmostColumnOfTheLastDisplayBelongsToTheNearestDisplay() {
        // AppKit's mouse rule is x in [minX, maxX): with no display to the right, x == maxX goes to the nearest.
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 2000, y: 400), in: [left, right]) == 1)
    }

    @Test func theSharedVerticalEdgeBelongsToTheDisplayOnTheRight() {
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 1000, y: 400), in: [left, right]) == 1)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 1000, y: 400), in: [right, left]) == 0)
    }

    @Test func theSharedHorizontalEdgeBelongsToTheLowerDisplay() {
        // A display stacked above: AppKit's rule is y in (minY, maxY], so the lower display's top row is its own.
        let lower = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let upper = CGRect(x: 0, y: 800, width: 1000, height: 600)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 500, y: 800), in: [lower, upper]) == 0)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 500, y: 800), in: [upper, lower]) == 1)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 500, y: 1400), in: [lower, upper]) == 1)
    }

    @Test func aPointInAGapBetweenDisplaysPicksTheNearerOne() {
        let gapped = CGRect(x: 1100, y: 0, width: 1000, height: 800)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 1010, y: 400), in: [left, gapped]) == 0)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 1090, y: 400), in: [left, gapped]) == 1)
    }

    @Test func aPointOffEveryDisplayPicksTheNearestNotTheFirst() {
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: 2500, y: 900), in: [left, right]) == 1)
        #expect(CursorBubbleLayout.displayIndex(containing: CGPoint(x: -300, y: -50), in: [left, right]) == 0)
    }

    @Test func noDisplaysPicksNothing() {
        #expect(CursorBubbleLayout.displayIndex(containing: .zero, in: []) == nil)
    }

    // MARK: Flight start and end: the target does not count yet

    @Test func whileFlyingOnlyThePointerIsInTheClearanceFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pointerPosition = CGPoint(x: 200, y: 900)
        let flying = CursorBubbleLayout.pointerClearanceFrame(
            pointerPosition: pointerPosition, screenFrame: screen, target: CGPoint(x: 700, y: 940), isPointerHoldingAtTarget: false)
        #expect(flying.size == CGSize(width: CursorBubbleLayout.pointerSize, height: CursorBubbleLayout.pointerSize))
        let holding = CursorBubbleLayout.pointerClearanceFrame(
            pointerPosition: pointerPosition, screenFrame: screen, target: CGPoint(x: 700, y: 940), isPointerHoldingAtTarget: true)
        #expect(holding.contains(CGPoint(x: 700, y: 940)))
    }

    @Test func atTheStartOfAFlightNearTheBottomTheBubbleStaysByThePointerNotOnTheFarTarget() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pointerPosition = CGPoint(x: 200, y: 930)  // top-left coordinates: 52 pt above the bottom edge
        let label = CursorBubbleLayout.pointerLabelFrame(
            pointerPosition: pointerPosition, labelSize: CGSize(width: 0, height: 22), fullLabelWidth: 0, screenFrame: screen)
        let target = CGPoint(x: 400, y: 950)
        let clearance = CursorBubbleLayout.pointerClearanceFrame(
            pointerPosition: pointerPosition, screenFrame: screen, target: target, isPointerHoldingAtTarget: false)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(label, clearing: clearance), bubbleSize: bubbleSize, visibleFrame: visibleFrame)
        let bubble = CGRect(origin: placement.origin, size: bubbleSize)
        #expect(bubble.minY < 200)
        #expect(!bubble.contains(target))
    }

    // MARK: A bubble that fits neither above nor below

    @Test func aTallBubbleOnAShortFrameGoesBesideTheClearanceFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 300)
        let tall = CGSize(width: 300, height: 200)
        let s = scene(target: CGPoint(x: 200, y: 150), screen: screen)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(s.label, clearing: s.clearance), bubbleSize: tall, visibleFrame: screen)
        let bubble = CGRect(origin: placement.origin, size: tall)
        #expect(screen.contains(bubble))
        #expect(!bubble.intersects(s.label))
        #expect(!bubble.intersects(s.clearance))
    }

    @Test func aTargetNearTheTopWithTheLabelLowPutsTheBubbleBesideThem() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 300)
        let tall = CGSize(width: 300, height: 200)
        let label = CGRect(x: 600, y: 20, width: 80, height: 22)
        let clearance = CGRect(x: 590, y: 20, width: 30, height: 270)
        let placement = CursorBubbleLayout.placement(
            anchor: .belowLabel(label, clearing: clearance), bubbleSize: tall, visibleFrame: screen)
        let bubble = CGRect(origin: placement.origin, size: tall)
        #expect(screen.contains(bubble))
        #expect(!bubble.intersects(label))
        #expect(!bubble.intersects(clearance))
    }

    @Test func withNoRoomBesideItTheBubbleTakesTheSideWithMoreRoomAndClampsOnlyThere() {
        let screen = CGRect(x: 0, y: 0, width: 320, height: 300)
        let tall = CGSize(width: 300, height: 200)
        // Room below the label is 94; room above the clearance frame is 172.
        let aboveWins = CursorBubbleLayout.placement(
            anchor: .belowLabel(CGRect(x: 10, y: 100, width: 80, height: 22), clearing: CGRect(x: 10, y: 100, width: 16, height: 10)),
            bubbleSize: tall, visibleFrame: screen)
        #expect(aboveWins.origin.y + tall.height == screen.maxY)
        // Room below the label is 14; room above the clearance frame is 4.
        let belowWins = CursorBubbleLayout.placement(
            anchor: .belowLabel(CGRect(x: 10, y: 20, width: 80, height: 22), clearing: CGRect(x: 10, y: 20, width: 16, height: 270)),
            bubbleSize: tall, visibleFrame: screen)
        #expect(belowWins.origin.y == screen.minY)
    }
}
