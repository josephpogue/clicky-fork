import CoreGraphics

/// Sizes a window so it opens fully inside the part of a screen that is not under the menu bar or Dock.
public enum WindowFit {
    /// The window frame (title bar included): `desiredContentSize` plus `windowChromeHeight`, shrunk to
    /// `visibleFrame` when it is too big, then centered inside `visibleFrame`.
    public static func frame(desiredContentSize: CGSize, windowChromeHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let width = min(desiredContentSize.width, visibleFrame.width)
        let height = min(desiredContentSize.height + windowChromeHeight, visibleFrame.height)
        return CGRect(
            x: visibleFrame.minX + (visibleFrame.width - width) / 2,
            y: visibleFrame.minY + (visibleFrame.height - height) / 2,
            width: width,
            height: height
        )
    }
}
