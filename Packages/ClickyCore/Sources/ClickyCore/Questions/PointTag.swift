import CoreGraphics
import Foundation

/// What a trailing [POINT:...] tag in an answer says.
public struct PointTagParseResult: Equatable, Sendable {
    /// The answer with the tag removed and trimmed
    public var spokenText: String
    /// Pixel coordinate in the image, nil for [POINT:none] or no tag
    public var coordinate: CGPoint?
    /// Short element label; "none" for [POINT:none]; nil when there is no tag or no label
    public var label: String?
    /// 1-based screen number named in the tag, nil to use the cursor screen
    public var screenNumber: Int?

    public init(spokenText: String, coordinate: CGPoint?, label: String?, screenNumber: Int?) {
        self.spokenText = spokenText
        self.coordinate = coordinate
        self.label = label
        self.screenNumber = screenNumber
    }
}

/// Parses `[POINT:x,y:label:screenN]` or `[POINT:none]` from the very end of an answer. Ported from upstream's parsePointingCoordinates.
public enum PointTagParser {
    public static func parse(_ answerText: String) -> PointTagParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: answerText, range: NSRange(answerText.startIndex..., in: answerText)),
              let tagRange = Range(match.range, in: answerText) else {
            return PointTagParseResult(spokenText: answerText, coordinate: nil, label: nil, screenNumber: nil)
        }

        let spokenText = String(answerText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: answerText),
              let yRange = Range(match.range(at: 2), in: answerText),
              let x = Double(answerText[xRange]),
              let y = Double(answerText[yRange]) else {
            return PointTagParseResult(spokenText: spokenText, coordinate: nil, label: "none", screenNumber: nil)
        }

        var label: String?
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: answerText) {
            label = String(answerText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int?
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: answerText) {
            screenNumber = Int(answerText[screenRange])
        }

        return PointTagParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            label: label,
            screenNumber: screenNumber
        )
    }
}

/// Turns a parsed tag into a point on the real screen.
public enum PointMapper {
    /// The tag's screen, else the cursor screen; nil when the tag has no coordinate or no shot fits.
    public static func globalPoint(
        for tag: PointTagParseResult,
        shots: [DisplayShot]
    ) -> (point: CGPoint, shot: DisplayShot)? {
        guard let coordinate = tag.coordinate else { return nil }

        let namedShot = tag.screenNumber.flatMap { number in shots.first { $0.screenNumber == number } }
        guard let shot = namedShot ?? shots.first(where: { $0.isCursorScreen }),
              shot.pixelWidth > 0, shot.pixelHeight > 0 else { return nil }

        let imageWidth = CGFloat(shot.pixelWidth)
        let imageHeight = CGFloat(shot.pixelHeight)
        let frame = shot.displayFrameInPoints

        // Clamp to the image, scale to display points, flip to a bottom-left origin, move to global coordinates
        let clampedX = max(0, min(coordinate.x, imageWidth))
        let clampedY = max(0, min(coordinate.y, imageHeight))
        let localX = clampedX * (frame.size.width / imageWidth)
        let localY = clampedY * (frame.size.height / imageHeight)
        let appKitY = frame.size.height - localY

        return (CGPoint(x: localX + frame.origin.x, y: appKitY + frame.origin.y), shot)
    }
}
