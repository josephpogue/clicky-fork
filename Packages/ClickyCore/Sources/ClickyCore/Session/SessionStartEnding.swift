import Foundation

/// What happens to the session folder when a Start ends without the session ever showing as running.
public enum SessionStartFolderOutcome: Equatable, Sendable {
    /// The folder and everything in it (log, shots) is deleted: the user never saw a session.
    case removeFolder
    /// The folder is finished as a short session and kept, with whatever it captured.
    case keepAsShortSession
}

/// How a Start that did not reach the red dot ends. Cancelling (the Start/Cancel press, or Quit) and failing
/// are different: a cancelled Start leaves nothing on disk even when capture had begun, because the user asked
/// for the session not to happen; a Start that fails for a real reason after capture began keeps its short
/// session and shows the failure notice, so the user can see what was captured.
public struct SessionStartEnding: Equatable, Sendable {
    public let folderOutcome: SessionStartFolderOutcome
    /// The notice for the panel and chat window; nil for a cancel.
    public let noticeText: String?

    /// - Parameters:
    ///   - isCancelled: the Start task was cancelled (Cancel pressed or Quit), at any step.
    ///   - failureNotice: why a Start failed for a real reason, when it did.
    ///   - captureBegan: the screen, microphone or key tap was switched on for this Start.
    public static func decide(isCancelled: Bool, failureNotice: String?, captureBegan: Bool) -> SessionStartEnding {
        if isCancelled {
            return SessionStartEnding(folderOutcome: .removeFolder, noticeText: nil)
        }
        return SessionStartEnding(
            folderOutcome: captureBegan ? .keepAsShortSession : .removeFolder,
            noticeText: failureNotice
        )
    }
}
