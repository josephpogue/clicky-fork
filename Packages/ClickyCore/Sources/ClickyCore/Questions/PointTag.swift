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

/// Parses `[POINT:x,y:label:screenN]` or `[POINT:none]` from an answer. Ported from upstream's parsePointingCoordinates,
/// but wherever the tag sits: the last well-formed tag is the one pointed at, and every `[POINT:...]` is
/// removed from the shown text, so the chat never shows raw tag text.
public enum PointTagParser {
    /// Anything that looks like a tag, well-formed or not; all of these are removed from the shown text.
    private static let anyTagPattern = #"\[POINT:[^\]]*\]"#

    /// A well-formed tag: `none`, or two numbers (decimals allowed) with an optional label that may hold
    /// colons, and an optional `:screenN` at the end. Spaces are allowed after `POINT:` and around the numbers.
    private static let wellFormedTagPattern =
        #"^\[POINT:\s*(?:none|(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?:\s*:(?!\s*screen\d+\s*\])([^\]]+?))?(?:\s*:\s*screen(\d+))?)\s*\]$"#

    public static func parse(_ answerText: String) -> PointTagParseResult {
        guard let anyTagRegex = try? NSRegularExpression(pattern: anyTagPattern),
              let wellFormedRegex = try? NSRegularExpression(pattern: wellFormedTagPattern) else {
            return PointTagParseResult(spokenText: answerText, coordinate: nil, label: nil, screenNumber: nil)
        }

        let wholeRange = NSRange(answerText.startIndex..., in: answerText)
        let tagMatches = anyTagRegex.matches(in: answerText, range: wholeRange)
        guard !tagMatches.isEmpty else {
            return PointTagParseResult(spokenText: answerText, coordinate: nil, label: nil, screenNumber: nil)
        }

        var shownText = ""
        var cursor = answerText.startIndex
        var lastWellFormed: PointTagParseResult?

        for tagMatch in tagMatches {
            guard let tagRange = Range(tagMatch.range, in: answerText) else { continue }
            let tagText = String(answerText[tagRange])

            if let parsedTag = parseWellFormedTag(tagText, using: wellFormedRegex) {
                lastWellFormed = parsedTag
            }

            // Keep the words before the tag, minus the spaces that led up to it.
            var before = String(answerText[cursor..<tagRange.lowerBound])
            while let lastCharacter = before.last, lastCharacter == " " || lastCharacter == "\t" {
                before.removeLast()
            }
            shownText += before
            cursor = tagRange.upperBound

            // "Click Save. [POINT:...]." would leave a doubled full stop; the stray one goes.
            if let lastShownCharacter = shownText.last, ".!?".contains(lastShownCharacter),
               cursor < answerText.endIndex, answerText[cursor] == "." {
                cursor = answerText.index(after: cursor)
            }
        }
        shownText += String(answerText[cursor...])
        let spokenText = shownText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let lastWellFormed else {
            return PointTagParseResult(spokenText: spokenText, coordinate: nil, label: nil, screenNumber: nil)
        }
        return PointTagParseResult(
            spokenText: spokenText, coordinate: lastWellFormed.coordinate,
            label: lastWellFormed.label, screenNumber: lastWellFormed.screenNumber
        )
    }

    /// The point, label and screen a single well-formed tag names; nil when the tag is malformed.
    private static func parseWellFormedTag(_ tagText: String, using regex: NSRegularExpression) -> PointTagParseResult? {
        guard let match = regex.firstMatch(in: tagText, range: NSRange(tagText.startIndex..., in: tagText)) else {
            return nil
        }
        guard let xRange = Range(match.range(at: 1), in: tagText),
              let yRange = Range(match.range(at: 2), in: tagText),
              let x = Double(tagText[xRange]),
              let y = Double(tagText[yRange]) else {
            // [POINT:none]
            return PointTagParseResult(spokenText: "", coordinate: nil, label: "none", screenNumber: nil)
        }

        var label: String?
        if let labelRange = Range(match.range(at: 3), in: tagText) {
            let trimmedLabel = tagText[labelRange].trimmingCharacters(in: .whitespaces)
            label = trimmedLabel.isEmpty ? nil : trimmedLabel
        }

        var screenNumber: Int?
        if let screenRange = Range(match.range(at: 4), in: tagText) {
            screenNumber = Int(tagText[screenRange])
        }

        // Whole pixels: the nearest one to a decimal coordinate.
        return PointTagParseResult(
            spokenText: "",
            coordinate: CGPoint(x: x.rounded(), y: y.rounded()),
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
