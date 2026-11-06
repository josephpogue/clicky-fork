import Foundation

/// Decides what the answer bubble beside the cursor does as an answer grows: show it, change its text in place,
/// or leave it alone. The AppKit presenter only carries out the returned action.
///
/// The bubble hides only on the user's click or key (`userDismissed`), never on a timer. After that dismissal a
/// later report brings it back only when it carries something new: text longer than what had been shown (a later
/// finding), or a final answer that differs from what had been shown. The same text never re-shows it.
public struct GrowingAnswerBubbleState: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case nothing
        /// No bubble is on screen: create one with this text (empty text with the checking line is the whole bubble).
        case show(text: String, showsCheckingLine: Bool)
        /// A bubble is on screen: change its text in place, with no fade and no re-show animation.
        case update(text: String, showsCheckingLine: Bool)
    }

    private var isOnScreen = false
    private var isDismissed = false
    /// The answer text the bubble last showed, or showed when the user dismissed it.
    private var shownText = ""
    private var showsCheckingLine = false

    public init() {}

    /// The visible answer so far (tags already removed). The checking line goes away with new text.
    public mutating func textReported(_ text: String) -> Action {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        if isDismissed {
            // Only a later finding is worth bringing the bubble back for.
            guard text.count > shownText.count else { return .nothing }
        } else if isOnScreen, text == shownText, !showsCheckingLine {
            return .nothing
        }
        return display(text: text, showsCheckingLine: false)
    }

    /// The model is searching: "Checking your notes" under the text so far, or alone before any text.
    public mutating func checkingLineReported() -> Action {
        guard !isDismissed, !showsCheckingLine || !isOnScreen else { return .nothing }
        return display(text: shownText, showsCheckingLine: true)
    }

    /// The final answer, after every progress report.
    public mutating func finalAnswerReported(_ text: String) -> Action {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        if isDismissed {
            guard text != shownText else { return .nothing }
        } else if isOnScreen, text == shownText, !showsCheckingLine {
            return .nothing
        }
        return display(text: text, showsCheckingLine: false)
    }

    /// The user clicked or pressed a key: the bubble faded away.
    public mutating func userDismissed() {
        guard isOnScreen else { return }
        isOnScreen = false
        isDismissed = true
        showsCheckingLine = false
    }

    /// The bubble was removed for another reason (a new question, Stop, a notice took its place).
    public mutating func reset() {
        self = GrowingAnswerBubbleState()
    }

    private mutating func display(text: String, showsCheckingLine: Bool) -> Action {
        let action: Action = isOnScreen
            ? .update(text: text, showsCheckingLine: showsCheckingLine)
            : .show(text: text, showsCheckingLine: showsCheckingLine)
        isOnScreen = true
        isDismissed = false
        shownText = text
        self.showsCheckingLine = showsCheckingLine
        return action
    }
}
