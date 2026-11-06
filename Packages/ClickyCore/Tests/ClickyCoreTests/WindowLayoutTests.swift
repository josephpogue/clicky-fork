import CoreGraphics
import Testing
@testable import ClickyCore

struct WindowLayoutTests {
    private let screenSize = CGSize(width: 1440, height: 900)
    private let labelSize = CGSize(width: 100, height: 24)

    private func labelFrame(centeredAt center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Pointer label

    @Test func labelSitsRightOfThePointerWhenThereIsRoom() {
        let center = PointerLabelLayout.center(
            pointerPosition: CGPoint(x: 100, y: 500), currentLabelSize: labelSize, fullLabelWidth: 100, screenSize: screenSize)
        // Right of the pointer: 100 + 10 gap + 100 / 2 = 160. Below it: 500 + 18 = 518.
        #expect(center == CGPoint(x: 160, y: 518))
    }

    @Test func labelFlipsLeftWhenThePointerIsTwentyPointsFromTheRightEdge() {
        let center = PointerLabelLayout.center(
            pointerPosition: CGPoint(x: 1420, y: 500), currentLabelSize: labelSize, fullLabelWidth: 100, screenSize: screenSize)
        // 1420 + 10 + 100 = 1530 passes 1440, so the label goes left: 1420 - 10 - 100 / 2 = 1360.
        #expect(center == CGPoint(x: 1360, y: 518))
        let frame = labelFrame(centeredAt: center, size: labelSize)
        // It spans 1310 to 1410, whole and inside the screen.
        #expect(frame.minX == 1310)
        #expect(frame.maxX == 1410)
        #expect(CGRect(origin: .zero, size: screenSize).contains(frame))
    }

    @Test func aLabelStillTypingStaysOnTheSideItsFullTextNeeds() {
        // Only 30 points are typed so far, but the full text is 100 wide, so the label already sits left.
        // Its right edge stays 10 left of the pointer: center = 1420 - 10 - 30 / 2 = 1395.
        let center = PointerLabelLayout.center(
            pointerPosition: CGPoint(x: 1420, y: 500),
            currentLabelSize: CGSize(width: 30, height: 24), fullLabelWidth: 100, screenSize: screenSize)
        #expect(center.x == 1395)
    }

    @Test func labelStaysInsideTheScreenNearTheBottomEdge() {
        let center = PointerLabelLayout.center(
            pointerPosition: CGPoint(x: 100, y: 895), currentLabelSize: labelSize, fullLabelWidth: 100, screenSize: screenSize)
        // 895 + 18 = 913 would pass 900. The label's bottom may reach 900 - 4 margin = 896, so its center is 896 - 12 = 884.
        #expect(center.y == 884)
    }

    @Test func labelStaysInsideTheScreenNearTheTopEdge() {
        let center = PointerLabelLayout.center(
            pointerPosition: CGPoint(x: 100, y: -10), currentLabelSize: labelSize, fullLabelWidth: 100, screenSize: screenSize)
        // -10 + 18 = 8 would put the label's top above the screen. Its top may sit at 4 margin, so its center is 4 + 12 = 16.
        #expect(center.y == 16)
    }

    @Test func aLabelWiderThanEitherSideIsPulledInsideTheScreen() {
        let wideLabel = CGSize(width: 800, height: 24)
        let center = PointerLabelLayout.center(
            pointerPosition: CGPoint(x: 700, y: 500), currentLabelSize: wideLabel, fullLabelWidth: 800, screenSize: screenSize)
        // Right needs 700 + 10 + 800 = 1510 and left needs 700 - 10 - 800 = -110: neither fits.
        // Right overflows by 70, left by 114 (before margin), so the label is pulled in: right edge 1440 - 4 = 1436, center 1036.
        let frame = labelFrame(centeredAt: center, size: wideLabel)
        #expect(frame.minX >= 4)
        #expect(frame.maxX <= 1436)
    }

    // MARK: Window fit

    @Test func settingsFitsAVisibleFrameOfA1024By768Display() {
        // Menu bar 25 and Dock 70 leave a visible frame 1024 wide and 673 high (origin y 70 in AppKit coordinates).
        let visibleFrame = CGRect(x: 0, y: 70, width: 1024, height: 673)
        let frame = WindowFit.frame(
            desiredContentSize: CGSize(width: 520, height: 760), windowChromeHeight: 28, visibleFrame: visibleFrame)
        // Content may be 673 - 28 = 645 high, so the whole window is 673 high and fills the visible frame's height.
        #expect(frame.height == 673)
        #expect(frame.width == 520)
        #expect(visibleFrame.contains(frame))
    }

    @Test func aWindowThatAlreadyFitsKeepsItsSizeAndIsCentered() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = WindowFit.frame(
            desiredContentSize: CGSize(width: 520, height: 760), windowChromeHeight: 28, visibleFrame: visibleFrame)
        // 760 + 28 = 788 high, 520 wide. Centered: x = (1440 - 520) / 2 = 460, y = (875 - 788) / 2 = 43.5.
        #expect(frame == CGRect(x: 460, y: 43.5, width: 520, height: 788))
    }

    @Test func aWindowWiderThanTheVisibleFrameIsNarrowedToIt() {
        let visibleFrame = CGRect(x: 100, y: 0, width: 400, height: 800)
        let frame = WindowFit.frame(
            desiredContentSize: CGSize(width: 520, height: 300), windowChromeHeight: 28, visibleFrame: visibleFrame)
        #expect(frame.width == 400)
        #expect(frame.minX == 100)
    }
}
