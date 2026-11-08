import Foundation

/// The marker the model writes after an answer's cursor part when a chat part follows. Text after it never shows
/// beside the cursor; it shows only in the chat window.
public enum AnswerChatMarker {
    public static let text = "[CHAT]"


    /// The text with every marker removed and the pieces around them trimmed and joined by `separator`; empty
    /// pieces are dropped. Every reader a person sees (log, recap, summary input, session detail) goes through this.
    public static func removing(from text: String, joinedBy separator: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines
        return text.components(separatedBy: Self.text)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}

/// One part of an answer. An answer is a run of parts: a new part starts at each tool call (a notes search) and at
/// each sentence that starts with "Correction:". Each part opens with its cursor text and may have chat text after
/// its own marker.
public struct AnswerPart: Equatable, Sendable {
    /// The text before the part's marker (or the whole part when it has none): trimmed, never holding a marker.
    public var cursorText: String
    /// The text after the part's marker: trimmed, no marker in it. Empty when the part has no marker.
    public var chatText: String
    /// True once the part's marker has arrived.
    public var hasChatMarker: Bool
    /// True when nothing more can be added to `cursorText`: its marker came, a later part began, a tool call began
    /// after it, or the answer is final. While false, the last sentence of `cursorText` may still be half-written.
    public var isCursorTextComplete: Bool

    public init(cursorText: String, chatText: String, hasChatMarker: Bool, isCursorTextComplete: Bool) {
        self.cursorText = cursorText
        self.chatText = chatText
        self.hasChatMarker = hasChatMarker
        self.isCursorTextComplete = isCursorTextComplete
    }
}

/// Follows one answer's reports in the order they arrive and splits it into parts. The coordinator keeps one per
/// answer, made fresh at each question.
public struct AnswerPartsTracker: Equatable, Sendable {
    public init() {}

    /// The visible answer so far (POINT tags removed, half-written tags and markers hidden), each time it grows.
    public mutating func textReported(_ visibleText: String) {
        latestVisibleText = visibleText
    }

    /// The model began a tool call: the text so far ends the current part, and text after it starts a new one.
    public mutating func toolCallStarted() {
        let boundary = latestVisibleText.count
        if boundary > 0 { toolCallBoundaries.append(boundary) }
    }

    /// The final answer text (POINT tags removed; markers still in it). Every part is complete after it.
    public mutating func finalReported(_ text: String) {
        // Only the tool calls that fall inside the text both versions share still mark a part's end.
        let streamed = Array(latestVisibleText)
        let final = Array(text)
        var commonPrefixLength = 0
        while commonPrefixLength < streamed.count, commonPrefixLength < final.count,
              streamed[commonPrefixLength] == final[commonPrefixLength] {
            commonPrefixLength += 1
        }
        toolCallBoundaries = toolCallBoundaries.filter { $0 <= commonPrefixLength }
        latestVisibleText = text
        isFinal = true
    }

    /// The parts in order. Empty before any text. Recomputed from the latest text and the tool-call boundaries.
    public var parts: [AnswerPart] {
        let characters = Array(latestVisibleText)
        guard !characters.isEmpty else { return [] }

        var cutPoints = Set<Int>()
        var boundaryIndex = 0
        while boundaryIndex < toolCallBoundaries.count {
            cutPoints.insert(min(toolCallBoundaries[boundaryIndex], characters.count))
            boundaryIndex += 1
        }
        for start in Self.correctionStarts(in: characters) { cutPoints.insert(start) }
        cutPoints.remove(0)
        cutPoints.insert(characters.count)
        let ordered = cutPoints.sorted()

        var parts: [AnswerPart] = []
        var segmentStart = 0
        var orderedIndex = 0
        while orderedIndex < ordered.count {
            let endOffset = ordered[orderedIndex]
            orderedIndex += 1
            let segment = String(characters[segmentStart..<endOffset])
            let isLast = endOffset == characters.count
            // A tool call at or after the part's end means nothing more is added to it.
            let toolCallFollows = toolCallBoundaries.contains { min($0, characters.count) >= endOffset }
            if let part = Self.part(from: segment, isComplete: isFinal || !isLast || toolCallFollows) {
                parts.append(part)
            }
            segmentStart = endOffset
        }
        return parts
    }

    /// The chat window's text for the whole answer: every part in order, its cursor text then its chat text, as
    /// paragraphs of one message. No marker in it.
    public var chatText: String {
        var paragraphs: [String] = []
        for part in parts {
            if !part.cursorText.isEmpty { paragraphs.append(part.cursorText) }
            if !part.chatText.isEmpty { paragraphs.append(part.chatText) }
        }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chat text of an answer that is no longer tracked (a cut-short report of an older answer): the same
    /// result as feeding `visibleText` alone, with no tool-call boundaries known.
    public static func chatText(ofVisibleText visibleText: String) -> String {
        var tracker = AnswerPartsTracker()
        tracker.textReported(visibleText)
        return tracker.chatText
    }

    private var latestVisibleText = ""
    /// Character counts of the visible text at each tool call, in order.
    private var toolCallBoundaries: [Int] = []
    private var isFinal = false

    /// One segment (no tool-call or Correction cut inside it) as a part, or nil when it holds nothing.
    private static func part(from segment: String, isComplete: Bool) -> AnswerPart? {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let pieces = segment.components(separatedBy: AnswerChatMarker.text).map { $0.trimmingCharacters(in: trimSet) }
        let hasMarker = pieces.count > 1
        let cursorText = pieces[0]
        var chatPieces: [String] = []
        var index = 1
        while index < pieces.count {
            if !pieces[index].isEmpty { chatPieces.append(pieces[index]) }
            index += 1
        }
        if cursorText.isEmpty && !hasMarker { return nil }
        return AnswerPart(
            cursorText: cursorText, chatText: chatPieces.joined(separator: "\n\n"), hasChatMarker: hasMarker,
            isCursorTextComplete: isComplete || hasMarker)
    }

    /// Offsets where a sentence starting with "Correction:" begins: at the start of the text (after any spaces) or
    /// after a sentence end followed by whitespace. The sentence-end rule is the speech splitter's.
    private static func correctionStarts(in characters: [Character]) -> [Int] {
        let word = Array("Correction:")
        var starts: [Int] = []
        func startsWord(at index: Int) -> Bool {
            guard index + word.count <= characters.count else { return false }
            var offset = 0
            while offset < word.count {
                if characters[index + offset] != word[offset] { return false }
                offset += 1
            }
            return true
        }
        var index = 0
        var atSentenceStart = true
        while index < characters.count {
            let character = characters[index]
            if atSentenceStart {
                if character.isWhitespace { index += 1; continue }
                if startsWord(at: index) { starts.append(index) }
                atSentenceStart = false
            }
            if ".!?".contains(character), index + 1 < characters.count, characters[index + 1].isWhitespace,
               !endsAbbreviation(characters, periodIndex: index) {
                atSentenceStart = true
            }
            index += 1
        }
        return starts
    }

    /// "e.g." and "i.e." end in a period but not a sentence.
    private static func endsAbbreviation(_ characters: [Character], periodIndex: Int) -> Bool {
        guard characters[periodIndex] == "." else { return false }
        for abbreviation in ["e.g.", "i.e."] {
            let length = abbreviation.count
            guard periodIndex + 1 >= length else { continue }
            if String(characters[(periodIndex + 1 - length)...periodIndex]).lowercased() == abbreviation { return true }
        }
        return false
    }
}
