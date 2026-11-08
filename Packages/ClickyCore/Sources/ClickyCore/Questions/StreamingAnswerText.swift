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
    private static let markerOpening = AnswerChatMarker.text

    public static func visible(rawTextSoFar: String) -> StreamingAnswerView {
        let withoutOpenTag = removingTrailingIncompleteTag(from: rawTextSoFar)
        let parsed = PointTagParser.parse(withoutOpenTag)
        // The visible text only ever grows at its end: leading whitespace never shows, in any state of the stream.
        var visibleText = String(parsed.spokenText.drop(while: { $0.isWhitespace }))
        // Hidden text (a half-written tag or marker, or a tag) takes the space that followed a sentence. The sentence
        // is finished all the same, so the space stays for it, and it shows without waiting for the final answer.
        if withoutOpenTag.count != rawTextSoFar.count || endsInCompleteTag(withoutOpenTag) {
            visibleText = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastCharacter = visibleText.last, ".!?".contains(lastCharacter) { visibleText += " " }
        }
        return StreamingAnswerView(visibleText: visibleText, firstCompletePoint: firstPoint(in: withoutOpenTag))
    }

    private static func endsInCompleteTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]"), let openRange = trimmed.range(of: tagOpening, options: .backwards) else { return false }
        return !trimmed[openRange.lowerBound...].dropLast().contains("]")
    }

    /// Cuts an unfinished `[POINT:...` (no closing bracket yet) or a trailing prefix of `[POINT:` or `[CHAT]` off the
    /// end. Every reader of a raw answer that may have been cut short uses it.
    public static func removingTrailingIncompleteTag(from text: String) -> String {
        if let openRange = text.range(of: tagOpening, options: .backwards),
           !text[openRange.lowerBound...].contains("]") {
            return String(text[..<openRange.lowerBound])
        }
        // A partial opening such as "[", "[P" or "[POINT", or a half-written chat marker such as "[CH", at the very
        // end. A complete "[CHAT]" stays: the answer parts need it.
        var prefixLength = min(tagOpening.count - 1, text.count)
        while prefixLength > 0 {
            let tail = String(text.suffix(prefixLength))
            let isHalfMarker = tail != markerOpening && markerOpening.hasPrefix(tail)
            if tagOpening.hasPrefix(tail) || isHalfMarker { return String(text.dropLast(prefixLength)) }
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
