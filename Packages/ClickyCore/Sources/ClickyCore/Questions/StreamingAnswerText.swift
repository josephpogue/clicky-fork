import Foundation

/// What to show of an answer that is still arriving.
public struct StreamingAnswerView: Equatable, Sendable {
    /// The text without any point tag, and without a tag still being written
    public var visibleText: String
    /// The first complete tag that points somewhere; nil for none or no complete tag yet
    public var firstCompletePoint: PointTagParseResult?
}

public enum StreamingAnswerText {
    private static let tagOpening = "[POINT:"

    public static func visible(rawTextSoFar: String) -> StreamingAnswerView {
        let withoutOpenTag = removingTrailingIncompleteTag(from: rawTextSoFar)
        let parsed = PointTagParser.parse(withoutOpenTag)
        // A text that ends in a tag keeps no space before it; "x [" trims its leading space the same way.
        var visibleText = parsed.spokenText
        if withoutOpenTag.count != rawTextSoFar.count {
            visibleText = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return StreamingAnswerView(visibleText: visibleText, firstCompletePoint: firstPoint(in: withoutOpenTag))
    }

    /// Cuts an unfinished `[POINT:...` (no closing bracket yet) or a trailing prefix of `[POINT:` off the end.
    private static func removingTrailingIncompleteTag(from text: String) -> String {
        if let openRange = text.range(of: tagOpening, options: .backwards),
           !text[openRange.lowerBound...].contains("]") {
            return String(text[..<openRange.lowerBound])
        }
        // A partial opening such as "[", "[P" or "[POINT" at the very end.
        var prefixLength = min(tagOpening.count - 1, text.count)
        while prefixLength > 0 {
            let tail = String(text.suffix(prefixLength))
            if tagOpening.hasPrefix(tail) { return String(text.dropLast(prefixLength)) }
            prefixLength -= 1
        }
        return text
    }

    private static func firstPoint(in text: String) -> PointTagParseResult? {
        guard let regex = try? NSRegularExpression(pattern: #"\[POINT:[^\]]*\]"#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for tagMatch in matches {
            guard let range = Range(tagMatch.range, in: text) else { continue }
            let single = PointTagParser.parse(String(text[range]))
            if single.coordinate != nil { return single }
        }
        return nil
    }
}
