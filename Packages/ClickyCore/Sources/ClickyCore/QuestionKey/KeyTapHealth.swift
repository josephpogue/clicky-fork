import Foundation

/// The notice shown when the key tap dies in a running session.
public enum KeyTapNotice {
    /// Names both keys, why they stopped and what to do. The same words as the Start failure, for a tap that
    /// worked at Start and was lost since.
    public static let lost = "The question key and the chat key stopped working because Clicky Fork lost Accessibility. Turn it on for Clicky Fork in System Settings, under Privacy and Security, then stop and start the session."
}

/// Decides when the key tap is gone for good. Every try to put the tap in place (a new tap after the keys changed,
/// turning it back on after macOS switched it off) reports its result here: one failed try is tried once more, a
/// second failure in a row is a loss, and a loss is reported once.
public struct KeyTapHealth: Equatable {
    public enum Verdict: Equatable {
        /// The tap works.
        case running
        /// The try failed; try once more now.
        case tryAgain
        /// The tap is gone for good: tell the user, once.
        case lost
        /// Already reported; tell nobody again.
        case alreadyLost
    }

    /// Failed tries in a row that make a loss.
    public static let failuresBeforeLoss = 2

    private var failuresInARow = 0
    private var hasReportedLoss = false

    public init() {}

    /// True from the loss until a try works again.
    public var isLost: Bool { hasReportedLoss }

    public mutating func attemptFinished(succeeded: Bool) -> Verdict {
        if succeeded {
            failuresInARow = 0
            hasReportedLoss = false
            return .running
        }
        failuresInARow += 1
        if failuresInARow < Self.failuresBeforeLoss { return .tryAgain }
        if hasReportedLoss { return .alreadyLost }
        hasReportedLoss = true
        return .lost
    }
}
