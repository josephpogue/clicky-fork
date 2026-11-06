import CoreGraphics
import Testing
@testable import ClickyCore

struct WindowPlacementTests {
    // Window content 620 x 640 plus 28 of title bar: a 620 x 668 frame. The chat panel is 360 x 520.
    private let contentSize = CGSize(width: 620, height: 640)
    private let chrome: CGFloat = 28

    private func place(visible: CGRect, panel: CGRect?) -> WindowPlacement.Result {
        WindowPlacement.place(
            desiredContentSize: contentSize, windowChromeHeight: chrome, visibleFrame: visible, chatPanelFrame: panel)
    }

    @Test func smallScreenPutsTheWindowLeftOfThePanelAtTheRightEdge() {
        // 1024 x 768 with a 24 high menu bar: visible frame (0, 0, 1024, 744).
        // Panel at the top right with a 20 margin: x = 1024 - 20 - 360 = 644, y = 744 - 20 - 520 = 204.
        let result = place(visible: CGRect(x: 0, y: 0, width: 1024, height: 744), panel: CGRect(x: 644, y: 204, width: 360, height: 520))
        // Room left of the panel: 644 - 12 gap - 0 = 632, so the 620 window is centered in it: x = (632 - 620) / 2 = 6.
        // Height 668 fits in 744, centered: y = (744 - 668) / 2 = 38.
        #expect(result.windowFrame == CGRect(x: 6, y: 38, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }

    @Test func bigScreenKeepsTheCenteredWindowWhenItDoesNotTouchThePanel() {
        // Visible frame (0, 0, 2560, 1415); panel x = 2560 - 20 - 360 = 2180, y = 1415 - 20 - 520 = 875.
        let result = place(visible: CGRect(x: 0, y: 0, width: 2560, height: 1415), panel: CGRect(x: 2180, y: 875, width: 360, height: 520))
        // Centered: x = (2560 - 620) / 2 = 970 (ends at 1590, well left of 2180); y = (1415 - 668) / 2 = 373.5.
        #expect(result.windowFrame == CGRect(x: 970, y: 373.5, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }

    @Test func panelDraggedToTheLeftSendsTheWindowToTheRight() {
        // Panel at x 20 to 380. Left room: 20 - 12 = 8, too small. Right room: 1024 - (380 + 12) = 632.
        let result = place(visible: CGRect(x: 0, y: 0, width: 1024, height: 744), panel: CGRect(x: 20, y: 204, width: 360, height: 520))
        // Centered in the right room: x = 392 + (632 - 620) / 2 = 398.
        #expect(result.windowFrame == CGRect(x: 398, y: 38, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }

    @Test func panelOnAnotherDisplayLeavesTheWindowCentered() {
        // Main display (0, 0, 1440, 875); second display to its right starts at x 1440 and holds the panel.
        let result = place(visible: CGRect(x: 0, y: 0, width: 1440, height: 875), panel: CGRect(x: 2980, y: 500, width: 360, height: 520))
        // Centered: x = (1440 - 620) / 2 = 410, y = (875 - 668) / 2 = 103.5.
        #expect(result.windowFrame == CGRect(x: 410, y: 103.5, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }

    @Test func windowOnTheSecondDisplayUsesThatDisplaysRoom() {
        // Second display visible frame (1440, 0, 1024, 744) holds both the window and the panel at its right edge:
        // panel x = 1440 + 1024 - 20 - 360 = 2084.
        let result = place(visible: CGRect(x: 1440, y: 0, width: 1024, height: 744), panel: CGRect(x: 2084, y: 204, width: 360, height: 520))
        // Left room: 2084 - 12 - 1440 = 632; x = 1440 + (632 - 620) / 2 = 1446.
        #expect(result.windowFrame == CGRect(x: 1446, y: 38, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }

    @Test func screenTooNarrowForBothLetsTheWindowWinAndLowersThePanel() {
        // Visible frame (0, 0, 800, 600); panel at x 420 to 780.
        let result = place(visible: CGRect(x: 0, y: 0, width: 800, height: 600), panel: CGRect(x: 420, y: 60, width: 360, height: 520))
        // Window height 668 is shrunk to 600; centered: x = (800 - 620) / 2 = 90, y = 0.
        // Left room 420 - 12 = 408 and right room 800 - 792 = 8 both hold less than 620.
        #expect(result.windowFrame == CGRect(x: 90, y: 0, width: 620, height: 600))
        #expect(result.chatPanelMustSitBehind == true)
    }

    @Test func noPanelOnScreenLeavesTheWindowCentered() {
        let result = place(visible: CGRect(x: 0, y: 0, width: 1024, height: 744), panel: nil)
        #expect(result.windowFrame == CGRect(x: 202, y: 38, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }

    @Test func panelBesideTheWindowWithoutOverlapDoesNotMoveIt() {
        // The window spans x 202 to 822. A small panel overlaps it in y but sits at x 900 to 1000, clear of it, so nothing moves.
        let result = place(visible: CGRect(x: 0, y: 0, width: 1024, height: 744), panel: CGRect(x: 900, y: 300, width: 100, height: 100))
        #expect(result.windowFrame == CGRect(x: 202, y: 38, width: 620, height: 668))
        #expect(result.chatPanelMustSitBehind == false)
    }
}
