import Foundation

/// Tracks the chat message of an answer that is still coming, and says what the chat should do for each report.
/// The coordinator carries the steps out on its `ChatWindowState`; this keeps the order of events testable.
public struct GrowingAnswerChatState: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Add the answer message with this text, marked still coming.
        case appendComingMessage(text: String)
        /// Replace the still-coming message's text.
        case replaceComingText(text: String)
        /// End the still-coming message with this text (the notes read, model and timing come from the caller).
        case finishComingMessage(text: String)
        /// Nothing was streaming: add the finished answer message as today.
        case appendFinishedMessage(text: String)
        case setCheckingNotes(Bool)
    }

    public static let cutShortLine = "(Cut short by your next question.)"

    /// The message text of an answer a newer question ended: what had arrived, then the cut-short line.
    public static func cutShortText(_ visibleText: String) -> String {
        let trimmed = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? cutShortLine : trimmed + "\n" + cutShortLine
    }

    public private(set) var hasComingMessage = false
    public private(set) var comingText = ""
    private var isCheckingNotes = false

    public init() {}

    public mutating func textReported(_ text: String) -> [Step] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var steps: [Step] = []
        if isCheckingNotes {
            isCheckingNotes = false
            steps.append(.setCheckingNotes(false))
        }
        steps.append(hasComingMessage ? .replaceComingText(text: text) : .appendComingMessage(text: text))
        hasComingMessage = true
        comingText = text
        return steps
    }

    public mutating func checkingReported() -> [Step] {
        guard !isCheckingNotes else { return [] }
        isCheckingNotes = true
        return [.setCheckingNotes(true)]
    }

    public mutating func finalAnswerReceived(_ text: String) -> [Step] {
        var steps = clearChecking()
        steps.append(hasComingMessage ? .finishComingMessage(text: text) : .appendFinishedMessage(text: text))
        endComing()
        return steps
    }

    /// A newer question ended the answer, or Stop, Quit or a new listening phase found it still coming.
    /// With a streamed message it is finished as cut short; without one and without text there is nothing to add.
    public mutating func cutShort(visibleText: String) -> [Step] {
        var steps = clearChecking()
        let text = visibleText.isEmpty && hasComingMessage ? comingText : visibleText
        if hasComingMessage {
            steps.append(.finishComingMessage(text: Self.cutShortText(text)))
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(.appendFinishedMessage(text: Self.cutShortText(text)))
        }
        endComing()
        return steps
    }

    /// Stop, Quit or a new listening phase: nothing is left coming, and the checking line goes.
    public mutating func abandon() -> [Step] {
        guard hasComingMessage else { return clearChecking() }
        return cutShort(visibleText: comingText)
    }

    /// A new session replaces the conversation: forget everything without touching any message.
    public mutating func reset() {
        self = GrowingAnswerChatState()
    }

    private mutating func clearChecking() -> [Step] {
        guard isCheckingNotes else { return [] }
        isCheckingNotes = false
        return [.setCheckingNotes(false)]
    }

    private mutating func endComing() {
        hasComingMessage = false
        comingText = ""
    }
}
