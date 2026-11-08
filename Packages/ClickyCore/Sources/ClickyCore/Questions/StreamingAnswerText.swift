import Foundation

/// What to show of an answer that is still arriving.
public struct StreamingAnswerView: Equatable, Sendable {
    /// The text without any point tag, and without a tag still being written
    public var visibleText: String
    /// The first complete tag that points somewhere; nil for none or no complete tag yet
    public var firstCompletePoint: PointTagParseResult?
    /// True when what was hidden at the end is a recognisable point tag or chat marker (or the start of one, at
    /// least three characters): the visible text ends there, so a sentence end before it is final even when the next
    /// word would have decided it ("... etc. [POINT:none]"). A lone "[" or "[C" does not count: it may be the start of
    /// ordinary text, so an unclear sentence end before it stays whole until the next character says more.
    public var endsBeforeHiddenText: Bool = false
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
            if endsWithSentenceMark(visibleText) { visibleText += " " }
        }
        let hiddenSuffix = String(rawTextSoFar.dropFirst(withoutOpenTag.count))
        let endsBeforeHiddenText = isRecognisableHiddenStart(hiddenSuffix) || endsInCompleteTag(withoutOpenTag)
        return StreamingAnswerView(
            visibleText: visibleText, firstCompletePoint: firstPoint(in: withoutOpenTag),
            endsBeforeHiddenText: endsBeforeHiddenText)
    }

    /// A sentence end mark, then at most closing quotes or brackets: the text ends where a sentence may have ended.
    private static func endsWithSentenceMark(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "\u{2019}", "\u{201D}", "\u{00BB}", ")", "]"]
        var characters = Array(text)
        while let last = characters.last, closers.contains(last) { characters.removeLast() }
        guard let mark = characters.last else { return false }
        return ".!?\u{2026}".contains(mark)
    }

    /// An unfinished point tag, or at least the first three characters of a point tag's or chat marker's name
    /// ("[PO", "[CH"): "[C" or "[P" may still be ordinary text such as "[Citation".
    private static func isRecognisableHiddenStart(_ hiddenSuffix: String) -> Bool {
        guard hiddenSuffix.count >= 3 else { return false }
        return hiddenSuffix.hasPrefix(tagOpening) || tagOpening.hasPrefix(hiddenSuffix) || markerOpening.hasPrefix(hiddenSuffix)
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
