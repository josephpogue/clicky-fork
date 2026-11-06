import CoreGraphics

/// Decides where a window the app opens (Settings, Sessions, a session detail) sits relative to the floating
/// chat panel, which stays above every window. Frames use AppKit's screen coordinates (origin bottom left).
public enum WindowPlacement {
    /// Space kept between the opened window and the chat panel.
    public static let gapBesidePanel: CGFloat = 12

    public struct Result: Equatable {
        /// Where the opened window goes.
        public let windowFrame: CGRect
        /// True when the screen has no room for both side by side: the opened window wins, and the chat
        /// panel must sit behind it so every control in the opened window stays visible and clickable.
        public let chatPanelMustSitBehind: Bool
    }

    /// Fits the window inside `visibleFrame` (see `WindowFit`), then keeps it clear of `chatPanelFrame`
    /// (nil when the panel is not on screen). The window stays centered when it does not touch the panel;
    /// otherwise it moves into the larger side with room for it, centered in that room.
    public static func place(
        desiredContentSize: CGSize, windowChromeHeight: CGFloat, visibleFrame: CGRect, chatPanelFrame: CGRect?
    ) -> Result {
        let centered = WindowFit.frame(
            desiredContentSize: desiredContentSize, windowChromeHeight: windowChromeHeight, visibleFrame: visibleFrame)
        guard let panel = chatPanelFrame, !centered.intersection(panel).isNull,
              centered.intersection(panel).width > 0, centered.intersection(panel).height > 0
        else {
            return Result(windowFrame: centered, chatPanelMustSitBehind: false)
        }

        let roomLeft = panel.minX - gapBesidePanel - visibleFrame.minX
        let roomRight = visibleFrame.maxX - (panel.maxX + gapBesidePanel)
        let leftFits = roomLeft >= centered.width
        let rightFits = roomRight >= centered.width
        if leftFits && (!rightFits || roomLeft >= roomRight) {
            return Result(windowFrame: centered.with(x: visibleFrame.minX + (roomLeft - centered.width) / 2), chatPanelMustSitBehind: false)
        }
        if rightFits {
            let roomStart = panel.maxX + gapBesidePanel
            return Result(windowFrame: centered.with(x: roomStart + (roomRight - centered.width) / 2), chatPanelMustSitBehind: false)
        }
        return Result(windowFrame: centered, chatPanelMustSitBehind: true)
    }
}

private extension CGRect {
    func with(x newX: CGFloat) -> CGRect {
        CGRect(x: newX, y: minY, width: width, height: height)
    }
}
