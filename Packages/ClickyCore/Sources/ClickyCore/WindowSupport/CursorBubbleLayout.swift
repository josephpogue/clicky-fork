import CoreGraphics

/// Placement and size rules for the answer bubble beside the cursor. Pure, so the flips and the
/// short/long choice are tested without a screen. Placement uses AppKit global coordinates
/// (origin bottom-left) and the visible frame of the display the cursor is on.
public enum CursorBubbleLayout {
    /// The bubble's top-left sits this far right of and below the cursor tip (the same spot as the question marker).
    public static let cursorOffset = CGSize(width: 18, height: 20)
    /// When flipped left, the bubble's right edge sits this far left of the cursor.
    public static let flippedLeftGap: CGFloat = 18
    /// When flipped up, the bubble's bottom edge sits this far above the cursor.
    public static let flippedUpGap: CGFloat = 8
    /// The gap between the pointer's label and a bubble riding under it.
    public static let gapBelowPointerLabel: CGFloat = 6

    public static let shortWidth: CGFloat = 300
    public static let longWidth: CGFloat = 340
    /// An answer needing more lines than this at the short width goes long.
    public static let shortLineLimit = 5
    /// The tallest the text body gets; anything past it is faded out and the footer points to the chat.
    public static let maximumBodyHeight: CGFloat = 197

    /// The corner of the bubble closest to what it hangs from; drawn with the small radius.
    public enum NearCorner: Equatable, Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    public struct Placement: Equatable, Sendable {
        public let origin: CGPoint
        public let nearCorner: NearCorner
    }

    /// Where the bubble goes by default, and where it goes when it flips left or up.
    public struct Anchor: Equatable, Sendable {
        public let defaultTopLeft: CGPoint
        public let flippedRightEdgeX: CGFloat
        public let flippedBottomEdgeY: CGFloat

        /// Beside the cursor: the default spot, the left flip and the up flip.
        public static func cursor(at cursorLocation: CGPoint) -> Anchor {
            Anchor(
                defaultTopLeft: CGPoint(x: cursorLocation.x + cursorOffset.width, y: cursorLocation.y - cursorOffset.height),
                flippedRightEdgeX: cursorLocation.x - flippedLeftGap,
                flippedBottomEdgeY: cursorLocation.y + flippedUpGap)
        }

        /// Under the pointer's label, left-aligned with it; flips to right-align, or above the label.
        public static func belowLabel(_ labelFrame: CGRect) -> Anchor {
            Anchor(
                defaultTopLeft: CGPoint(x: labelFrame.minX, y: labelFrame.minY - gapBelowPointerLabel),
                flippedRightEdgeX: labelFrame.maxX,
                flippedBottomEdgeY: labelFrame.maxY + gapBelowPointerLabel)
        }
    }

    public static func placement(anchor: Anchor, bubbleSize: CGSize, visibleFrame: CGRect) -> Placement {
        var originX = anchor.defaultTopLeft.x
        var originY = anchor.defaultTopLeft.y - bubbleSize.height
        var flippedLeft = false
        var flippedUp = false
        if originX + bubbleSize.width > visibleFrame.maxX {
            originX = anchor.flippedRightEdgeX - bubbleSize.width
            flippedLeft = true
        }
        if originY < visibleFrame.minY {
            originY = anchor.flippedBottomEdgeY
            flippedUp = true
        }
        originX = min(max(originX, visibleFrame.minX), visibleFrame.maxX - bubbleSize.width)
        originY = min(max(originY, visibleFrame.minY), visibleFrame.maxY - bubbleSize.height)

        let nearCorner: NearCorner
        switch (flippedLeft, flippedUp) {
        case (false, false): nearCorner = .topLeading
        case (true, false): nearCorner = .topTrailing
        case (false, true): nearCorner = .bottomLeading
        case (true, true): nearCorner = .bottomTrailing
        }
        return Placement(origin: CGPoint(x: originX, y: originY), nearCorner: nearCorner)
    }

    /// The pointer label's frame in AppKit global coordinates, from the pointer's position in the
    /// overlay's top-left coordinates. Uses `PointerLabelLayout`, the rule the overlay draws the label with.
    public static func pointerLabelFrame(
        pointerPosition: CGPoint,
        labelSize: CGSize,
        fullLabelWidth: CGFloat,
        screenFrame: CGRect
    ) -> CGRect {
        let labelCenter = PointerLabelLayout.center(
            pointerPosition: pointerPosition,
            currentLabelSize: labelSize,
            fullLabelWidth: fullLabelWidth,
            screenSize: screenFrame.size)
        let globalCenterY = screenFrame.maxY - labelCenter.y
        return CGRect(
            x: screenFrame.minX + labelCenter.x - labelSize.width / 2,
            y: globalCenterY - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height)
    }

    public struct TextLayout: Equatable, Sendable {
        public let width: CGFloat
        public let bodyHeight: CGFloat
        /// True when the body is cut at the cap: its bottom fades and the footer shows.
        public let isBodyCut: Bool
    }

    /// Short (300 wide) when the text fits in five lines at that width; otherwise long (340 wide), with the body
    /// capped at 197 pt and cut only when its natural height at 340 wide is taller than that.
    public static func textLayout(
        lineCountAtShortWidth: Int,
        naturalBodyHeightAtShortWidth: CGFloat,
        naturalBodyHeightAtLongWidth: CGFloat
    ) -> TextLayout {
        if lineCountAtShortWidth <= shortLineLimit {
            return TextLayout(width: shortWidth, bodyHeight: naturalBodyHeightAtShortWidth, isBodyCut: false)
        }
        let isCut = naturalBodyHeightAtLongWidth > maximumBodyHeight
        return TextLayout(
            width: longWidth,
            bodyHeight: isCut ? maximumBodyHeight : naturalBodyHeightAtLongWidth,
            isBodyCut: isCut)
    }
}
