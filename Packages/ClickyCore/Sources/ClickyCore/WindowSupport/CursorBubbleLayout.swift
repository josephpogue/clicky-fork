import CoreGraphics
import Foundation

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
    /// The gap between the clearance frame and a bubble placed beside it.
    public static let gapBesideClearance: CGFloat = 8

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
        /// The label, pointer and target a bubble must stay off, when the anchor hangs from a pointer label.
        public let avoidFrame: CGRect?

        public init(defaultTopLeft: CGPoint, flippedRightEdgeX: CGFloat, flippedBottomEdgeY: CGFloat, avoidFrame: CGRect? = nil) {
            self.defaultTopLeft = defaultTopLeft
            self.flippedRightEdgeX = flippedRightEdgeX
            self.flippedBottomEdgeY = flippedBottomEdgeY
            self.avoidFrame = avoidFrame
        }

        /// Beside the cursor: the default spot, the left flip and the up flip.
        public static func cursor(at cursorLocation: CGPoint) -> Anchor {
            Anchor(
                defaultTopLeft: CGPoint(x: cursorLocation.x + cursorOffset.width, y: cursorLocation.y - cursorOffset.height),
                flippedRightEdgeX: cursorLocation.x - flippedLeftGap,
                flippedBottomEdgeY: cursorLocation.y + flippedUpGap)
        }

        /// Under the pointer's label, left-aligned with it; flips to right-align, or above the label.
        /// `clearing` is the pointer and the spot it points at: a bubble flipped up sits above the top of
        /// the union of that frame and the label, so it never covers either.
        public static func belowLabel(_ labelFrame: CGRect, clearing: CGRect? = nil) -> Anchor {
            let top = clearing.map { max(labelFrame.maxY, $0.maxY) } ?? labelFrame.maxY
            return Anchor(
                defaultTopLeft: CGPoint(x: labelFrame.minX, y: labelFrame.minY - gapBelowPointerLabel),
                flippedRightEdgeX: labelFrame.maxX,
                flippedBottomEdgeY: top + gapBelowPointerLabel,
                avoidFrame: clearing.map { labelFrame.union($0) } ?? labelFrame)
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
        if flippedUp, let avoidFrame = anchor.avoidFrame, originY + bubbleSize.height > visibleFrame.maxY {
            return placementWhenFlippedBubbleOverflowsTop(
                anchor: anchor, avoidFrame: avoidFrame, bubbleSize: bubbleSize, visibleFrame: visibleFrame, flippedLeft: flippedLeft)
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

    /// The bubble fits neither below the label nor above the clearance frame. Put it beside the frame (right
    /// first, then left) when there is room, so it covers nothing; otherwise pin it to the screen edge on the
    /// side (above or below) with more room, and let the clamp act only there.
    private static func placementWhenFlippedBubbleOverflowsTop(
        anchor: Anchor,
        avoidFrame: CGRect,
        bubbleSize: CGSize,
        visibleFrame: CGRect,
        flippedLeft: Bool
    ) -> Placement {
        let sideOriginY = min(max(anchor.defaultTopLeft.y - bubbleSize.height, visibleFrame.minY), visibleFrame.maxY - bubbleSize.height)
        let rightOriginX = avoidFrame.maxX + gapBesideClearance
        if rightOriginX + bubbleSize.width <= visibleFrame.maxX {
            return Placement(origin: CGPoint(x: rightOriginX, y: sideOriginY), nearCorner: .topLeading)
        }
        let leftOriginX = avoidFrame.minX - gapBesideClearance - bubbleSize.width
        if leftOriginX >= visibleFrame.minX {
            return Placement(origin: CGPoint(x: leftOriginX, y: sideOriginY), nearCorner: .topTrailing)
        }

        let roomAbove = visibleFrame.maxY - anchor.flippedBottomEdgeY
        let roomBelow = anchor.defaultTopLeft.y - visibleFrame.minY
        let clampedOriginX = min(max(
            flippedLeft ? anchor.flippedRightEdgeX - bubbleSize.width : anchor.defaultTopLeft.x,
            visibleFrame.minX), visibleFrame.maxX - bubbleSize.width)
        if roomAbove >= roomBelow {
            let originY = max(visibleFrame.maxY - bubbleSize.height, visibleFrame.minY)
            return Placement(origin: CGPoint(x: clampedOriginX, y: originY), nearCorner: flippedLeft ? .bottomTrailing : .bottomLeading)
        }
        return Placement(origin: CGPoint(x: clampedOriginX, y: visibleFrame.minY), nearCorner: flippedLeft ? .topTrailing : .topLeading)
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

    /// The pointer triangle's size, as the overlay draws it.
    public static let pointerSize: CGFloat = 16
    /// Room kept around the spot the pointer points at.
    public static let targetClearance: CGFloat = 4

    /// What a bubble flipped above the label must clear, in AppKit global coordinates: the pointer triangle
    /// (from its position in the overlay's top-left coordinates) and the target it points at, when known.
    public static func pointerClearanceFrame(
        pointerPosition: CGPoint,
        screenFrame: CGRect,
        target: CGPoint?,
        isPointerHoldingAtTarget: Bool
    ) -> CGRect {
        let pointerFrame = CGRect(
            x: screenFrame.minX + pointerPosition.x - pointerSize / 2,
            y: screenFrame.maxY - pointerPosition.y - pointerSize / 2,
            width: pointerSize,
            height: pointerSize)
        // While the pointer flies, only it counts: the target is far off, and clearing it would throw the bubble across the screen.
        guard isPointerHoldingAtTarget, let target else { return pointerFrame }
        let targetFrame = CGRect(x: target.x, y: target.y, width: 0, height: 0)
            .insetBy(dx: -targetClearance, dy: -targetClearance)
        return pointerFrame.union(targetFrame)
    }

    /// The index of the display holding `point` by AppKit's mouse rule (x in [minX, maxX), y in (minY, maxY],
    /// as `NSMouseInRect(point, frame, false)`), so a shared edge belongs to one display only. A point on no
    /// display goes to the nearest one, edges counting as inside.
    public static func displayIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        for index in frames.indices {
            let frame = frames[index]
            if point.x >= frame.minX, point.x < frame.maxX, point.y > frame.minY, point.y <= frame.maxY {
                return index
            }
        }
        var best: (index: Int, distance: CGFloat)?
        for index in frames.indices {
            let frame = frames[index]
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = hypot(dx, dy)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// The "Checking your notes" line at the end of the bubble: its row height, and the gap above it when text sits above.
    public static let checkingLineHeight: CGFloat = 18
    public static let checkingLineGap: CGFloat = 8
    /// The bubble's width when the checking line shows alone, before any answer text has come: just wide
    /// enough for the line, so it reads as a small status, not an empty answer.
    public static let checkingLineAloneWidth: CGFloat = 174

    public struct TextLayout: Equatable, Sendable {
        public let width: CGFloat
        /// The height of the answer text as drawn. Zero when no text has come yet. Text that went through
        /// `AnswerBubbleMetrics.fitsInBubble` is never taller than `maximumBodyHeight`, so nothing is cut.
        public let bodyHeight: CGFloat
        /// The height the checking line adds under the body (its gap included), or zero when it is off.
        public let checkingLineExtraHeight: CGFloat

        /// Body plus checking line: everything between the bubble's top and bottom padding except the footer.
        public var contentHeight: CGFloat { bodyHeight + checkingLineExtraHeight }
    }

    /// True when text with these measurements fits the bubble with nothing cut: at most `shortLineLimit` lines at
    /// the short width, or a body at the long width no taller than `maximumBodyHeight`.
    public static func fits(lineCountAtShortWidth: Int, naturalBodyHeightAtLongWidth: CGFloat) -> Bool {
        lineCountAtShortWidth <= shortLineLimit || naturalBodyHeightAtLongWidth <= maximumBodyHeight
    }

    /// Short (300 wide) when the text fits in five lines at that width; otherwise long (340 wide) at its natural
    /// height. `showsCheckingLine` adds the "Checking your notes" line under the body; with no text at all (zero
    /// lines) the bubble is the checking line alone.
    public static func textLayout(
        lineCountAtShortWidth: Int,
        naturalBodyHeightAtShortWidth: CGFloat,
        naturalBodyHeightAtLongWidth: CGFloat,
        showsCheckingLine: Bool = false
    ) -> TextLayout {
        if lineCountAtShortWidth == 0 && showsCheckingLine {
            return TextLayout(width: checkingLineAloneWidth, bodyHeight: 0, checkingLineExtraHeight: checkingLineHeight)
        }
        let checkingLineExtraHeight = showsCheckingLine ? checkingLineGap + checkingLineHeight : 0
        if lineCountAtShortWidth <= shortLineLimit {
            return TextLayout(
                width: shortWidth, bodyHeight: naturalBodyHeightAtShortWidth,
                checkingLineExtraHeight: checkingLineExtraHeight)
        }
        return TextLayout(
            width: longWidth, bodyHeight: naturalBodyHeightAtLongWidth,
            checkingLineExtraHeight: checkingLineExtraHeight)
    }
}
