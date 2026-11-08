import Foundation

/// What the chat window's footer says while a session runs and no question is open.
public enum ChatFooter {
    public enum IdleLine: Equatable, Sendable {
        /// "Press [key] to ask", with the key drawn inside the sentence.
        case pressKeyToAsk
        /// A plain sentence, no key pill.
        case plain(String)
    }

    /// Shown from the moment the key tap dies until Stop or the next Start.
    public static let keyLostText = "The question key stopped working: turn on Accessibility, then stop and start the session."

    public static func idleLine(isKeyTapLost: Bool) -> IdleLine {
        isKeyTapLost ? .plain(keyLostText) : .pressKeyToAsk
    }
}
