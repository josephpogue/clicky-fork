import Foundation

/// The footer under (or instead of) the cursor line: where the rest of the answer is. Pure, so what the footer says
/// is tested, and the presenter redraws a bubble on screen the moment the key it names stops being true.
public enum CursorFooter {
    /// What the footer says when the chat key does not work (outside a session, or an inactive chat key).
    public static let openChatInMenuBarText = "More in Open chat, in the menu bar"

    /// The footer for `line`, or nil when the line holds everything. `chatKeyName` is the working chat key's name
    /// ("Right ⌘ ,"), nil when pressing it opens nothing. `showsCheckingLine` is true while "Checking your notes"
    /// is on the bubble: a footer-only line then drops its footer ("Answer in chat" would claim an answer that is
    /// still being searched for), so the bubble says only what Clicky is doing.
    public static func text(for line: CursorLine, chatKeyName: String?, showsCheckingLine: Bool = false) -> String? {
        guard line.hasMoreInChat else { return nil }
        if line.text.isEmpty && showsCheckingLine { return nil }
        guard let chatKeyName else { return openChatInMenuBarText }
        return line.text.isEmpty ? "Answer in chat: \(chatKeyName)" : "More in chat: \(chatKeyName)"
    }

    /// True when a bubble showing `line` must be redrawn because the key name changed from `oldChatKeyName` to
    /// `newChatKeyName`: it shows a footer, and that footer reads differently now.
    public static func needsRedraw(
        line: CursorLine, showsCheckingLine: Bool, oldChatKeyName: String?, newChatKeyName: String?
    ) -> Bool {
        text(for: line, chatKeyName: oldChatKeyName, showsCheckingLine: showsCheckingLine)
            != text(for: line, chatKeyName: newChatKeyName, showsCheckingLine: showsCheckingLine)
    }
}
