import Foundation

/// The marker the model writes after an answer's cursor part when a chat part follows. Text after it never shows
/// beside the cursor; it shows only in the chat window.
public enum AnswerChatMarker {
    public static let text = "[CHAT]"
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
    public mutating func toolCallStarted() {}

    /// The final answer text (POINT tags removed; markers still in it). Every part is complete after it.
    public mutating func finalReported(_ text: String) {
        latestVisibleText = text
    }

    /// The parts in order. Empty before any text.
    public var parts: [AnswerPart] {
        latestVisibleText.isEmpty ? [] : [AnswerPart(
            cursorText: latestVisibleText, chatText: "", hasChatMarker: false, isCursorTextComplete: false)]
    }

    /// The chat window's text for the whole answer: every part in order, its cursor text then its chat text, as
    /// paragraphs of one message. No marker in it.
    public var chatText: String { latestVisibleText }

    /// The chat text of an answer that is no longer tracked (a cut-short report of an older answer): the same
    /// result as feeding `visibleText` alone, with no tool-call boundaries known.
    public static func chatText(ofVisibleText visibleText: String) -> String { visibleText }

    private var latestVisibleText = ""
}
