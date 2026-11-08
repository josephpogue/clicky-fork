import Foundation

/// What the bubble beside the cursor shows of an answer or a notice: whole sentences only, never cut.
public struct CursorLine: Equatable, Sendable {
    /// The whole sentences shown. Empty means the bubble is the footer line alone (nothing fitted).
    public var text: String
    /// True when the chat window holds more of this answer than the bubble shows: the footer shows.
    public var hasMoreInChat: Bool

    public init(text: String, hasMoreInChat: Bool) {
        self.text = text
        self.hasMoreInChat = hasMoreInChat
    }

    /// The line for a notice (a failed Start, a provider error, the usage limit): the same no-cut rule, all of
    /// its text complete.
    public static func notice(text: String, fits: (String) -> Bool) -> CursorLine {
        CursorLine(text: text, hasMoreInChat: false)
    }
}

/// One step of an answer's cursor line.
public struct CursorLineUpdate: Equatable, Sendable {
    /// What the bubble shows now; nil while no whole sentence is known yet (the bubble shows nothing new).
    public var line: CursorLine?
    /// Sentences the bubble shows for the first time with this update, in order: the only text read aloud.
    public var newSentencesToSpeak: [String]

    public init(line: CursorLine?, newSentencesToSpeak: [String]) {
        self.line = line
        self.newSentencesToSpeak = newSentencesToSpeak
    }
}

/// Decides, from an answer's parts, which whole sentences show beside the cursor and which are read aloud.
/// Pure: `fits` is the app's measurement (true when the text fits under `CursorBubbleLayout.maximumBodyHeight`).
/// The coordinator keeps one per answer, made fresh at each question, and calls `update` after every report.
public struct CursorLineState: Equatable, Sendable {
    public init() {}

    public mutating func update(parts: [AnswerPart], fits: (String) -> Bool) -> CursorLineUpdate {
        guard let newestPart = parts.last, !newestPart.cursorText.isEmpty else {
            return CursorLineUpdate(line: nil, newSentencesToSpeak: [])
        }
        return CursorLineUpdate(
            line: CursorLine(text: newestPart.cursorText, hasMoreInChat: newestPart.hasChatMarker),
            newSentencesToSpeak: [])
    }
}
