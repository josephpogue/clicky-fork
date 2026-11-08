import Foundation

/// What a press of the chat key does to the chat window.
public enum ChatKeyPressAction: Equatable {
    case show
    case hide
    /// The window is open but a Settings or Sessions window covers it: bring it forward instead of closing a
    /// window the user cannot see.
    case bringToFront

    public static func forPress(isVisible: Bool, isBehindAnotherWindow: Bool) -> ChatKeyPressAction {
        guard isVisible else { return .show }
        return isBehindAnotherWindow ? .bringToFront : .hide
    }
}
