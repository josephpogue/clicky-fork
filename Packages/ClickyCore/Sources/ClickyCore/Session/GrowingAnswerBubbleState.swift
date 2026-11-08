import Foundation

/// Decides what the answer bubble beside the cursor does as an answer grows: show it, change its text in place,
/// or leave it alone. The AppKit presenter only carries out the returned action.
///
/// The bubble hides only on the user's click or key (`userDismissed`), never on a timer. After that dismissal a
/// later report brings it back only when it carries something new: a line that arrives after a checking line or a
/// tool call started since the dismissal (a later finding). The final line follows the same rule.
/// A line that did not change never re-shows it, so a click during streaming is not undone.
public struct GrowingAnswerBubbleState: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case nothing
        /// No bubble is on screen: create one with this line (empty text with the checking line is the whole bubble;
        /// empty text with `hasMoreInChat` is the footer alone).
        case show(line: CursorLine, showsCheckingLine: Bool)
        /// A bubble is on screen: change its line in place, with no fade and no re-show animation.
        case update(line: CursorLine, showsCheckingLine: Bool)
        /// The bubble on screen showed only "Checking your notes" and the answer ended with nothing to show in its
        /// place: remove it.
        case hide
    }

    private var isOnScreen = false
    private var isDismissed = false
    /// The line the bubble last showed, or showed when the user dismissed it.
    private var shownLine = CursorLine(text: "", hasMoreInChat: false)
    private var showsCheckingLine = false
    /// A checking line or tool call started since the user dismissed the bubble: the next text is a new finding.
    private var hasNewFindingSinceDismissal = false

    public init() {}

    /// The answer's cursor line, each time it changes (streaming and final alike). The checking line goes away with it.
    /// A line with no text and no footer shows nothing.
    public mutating func lineReported(_ line: CursorLine) -> Action {
        guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.hasMoreInChat else { return .nothing }
        if isDismissed {
            // Only a line after a search that started since the dismissal is worth bringing the bubble back for.
            guard hasNewFindingSinceDismissal, line != shownLine else { return .nothing }
        } else if isOnScreen, line == shownLine, !showsCheckingLine {
            return .nothing
        }
        return display(line: line, showsCheckingLine: false)
    }

    /// The model is searching: "Checking your notes" under the text so far, or alone before any text.
    public mutating func checkingLineReported() -> Action {
        if isDismissed {
            hasNewFindingSinceDismissal = true
            return .nothing
        }
        guard !showsCheckingLine || !isOnScreen else { return .nothing }
        return display(line: shownLine, showsCheckingLine: true)
    }

    /// The model began a tool call. While the bubble is dismissed, text that follows is a new finding.
    public mutating func toolCallStartedReported() {
        if isDismissed { hasNewFindingSinceDismissal = true }
    }

    /// The answer ended (the final answer, or an answer cut short for any reason): "Checking your notes" never stays
    /// on it, even when the final line is the one already shown (so `lineReported` was not called again). A bubble
    /// that showed the checking line alone has nothing else to show: it goes.
    public mutating func answerFinished() -> Action {
        guard isOnScreen, showsCheckingLine else { return .nothing }
        guard !shownLine.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shownLine.hasMoreInChat else {
            isOnScreen = false
            showsCheckingLine = false
            return .hide
        }
        return display(line: shownLine, showsCheckingLine: false)
    }

    /// The user clicked or pressed a key: the bubble faded away.
    public mutating func userDismissed() {
        guard isOnScreen else { return }
        isOnScreen = false
        isDismissed = true
        // A bubble that showed "Checking your notes" (alone or under text) had no finding yet: the search it announced
        // is still under way, so the next text that differs from what was shown is that search's finding.
        hasNewFindingSinceDismissal = showsCheckingLine
        showsCheckingLine = false
    }

    /// The bubble was removed for another reason (a new question, Stop, a notice took its place).
    public mutating func reset() {
        self = GrowingAnswerBubbleState()
    }

    private mutating func display(line: CursorLine, showsCheckingLine: Bool) -> Action {
        let action: Action = isOnScreen
            ? .update(line: line, showsCheckingLine: showsCheckingLine)
            : .show(line: line, showsCheckingLine: showsCheckingLine)
        isOnScreen = true
        isDismissed = false
        hasNewFindingSinceDismissal = false
        shownLine = line
        self.showsCheckingLine = showsCheckingLine
        return action
    }
}
