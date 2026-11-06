import CoreGraphics

/// Where the label beside the flying pointer is drawn, in the overlay's top-left coordinates.
/// The label goes right of the pointer, flips to the left when its full text would pass the screen's
/// right edge, and is kept inside the screen vertically, so it is never cut off.
public enum PointerLabelLayout {
    /// Distance from the pointer's center to the label's near edge.
    public static let gapFromPointer: CGFloat = 10
    /// How far below the pointer's center the label's center sits.
    public static let verticalOffsetBelowPointer: CGFloat = 18
    /// The closest the label may come to any screen edge.
    public static let screenEdgeMargin: CGFloat = 4

    /// - Parameters:
    ///   - currentLabelSize: the label as drawn now (it grows while its text types out).
    ///   - fullLabelWidth: the width of the finished text, so the side is chosen once and does not flip mid-typing.
    public static func center(
        pointerPosition: CGPoint,
        currentLabelSize: CGSize,
        fullLabelWidth: CGFloat,
        screenSize: CGSize
    ) -> CGPoint {
        let fitsRightOfPointer = pointerPosition.x + gapFromPointer + fullLabelWidth <= screenSize.width - screenEdgeMargin
        let unclampedCenterX = fitsRightOfPointer
            ? pointerPosition.x + gapFromPointer + currentLabelSize.width / 2
            : pointerPosition.x - gapFromPointer - currentLabelSize.width / 2
        let unclampedCenterY = pointerPosition.y + verticalOffsetBelowPointer
        return CGPoint(
            x: clamp(unclampedCenterX, halfExtent: currentLabelSize.width / 2, limit: screenSize.width),
            y: clamp(unclampedCenterY, halfExtent: currentLabelSize.height / 2, limit: screenSize.height)
        )
    }

    private static func clamp(_ center: CGFloat, halfExtent: CGFloat, limit: CGFloat) -> CGFloat {
        let lowest = halfExtent + screenEdgeMargin
        let highest = limit - halfExtent - screenEdgeMargin
        // A label bigger than the screen cannot fit: keep its start on screen.
        if highest < lowest { return lowest }
        return min(max(center, lowest), highest)
    }
}
