import Foundation

/// The notice shown when the key tap dies in a running session.
public enum KeyTapNotice {
    /// Names both keys, why they stopped and what to do. The same words as the Start failure, for a tap that
    /// worked at Start and was lost since.
    public static let lost = "The question key and the chat key stopped working because Clicky Fork lost Accessibility. Turn it on for Clicky Fork in System Settings, under Privacy and Security, then stop and start the session."

    /// What a question being listened for hears when the keys die: it can no longer be sent, so it is dropped.
    private static let questionDroppedSentence = " The question you were asking was not sent."

    /// The notice for a loss, with the dropped question named when one was being listened for.
    public static func text(questionDropped: Bool) -> String {
        questionDropped ? lost + questionDroppedSentence : lost
    }

    /// True for either wording of the loss notice, so Stop can clear exactly that panel line and no other.
    public static func isLossNotice(_ text: String?) -> Bool {
        guard let text else { return false }
        return text == lost || text == lost + questionDroppedSentence
    }

    /// What a Settings key section says while the tap is lost: which key, why, and the fix.
    public static func settingsLine(keyName: String) -> String {
        "The \(keyName) stopped working because Clicky Fork lost Accessibility. Turn it on for Clicky Fork in System Settings, under Privacy and Security, then stop and start the session."
    }
}

/// What the user sees after the key tap died, and when. The lost state shows in Settings from the loss until the
/// next Start or Stop. The cursor notice shows at once, or waits until the answer that is still coming has ended and
/// its reading has finished, so losing the keys never cuts an answer.
public struct KeyTapLossState: Equatable {
    public enum CursorNotice: Equatable {
        /// Show the notice beside the cursor now.
        case showNow(String)
        /// An answer is in flight or being read: the notice waits.
        case deferred
        /// Already reported this session: nothing to do.
        case none
    }

    /// True from the loss until the next Start or Stop.
    public private(set) var isLost = false
    /// The cursor notice waiting for the answer to end and its reading to finish.
    public private(set) var deferredCursorText: String?

    public init() {}

    public mutating func tapLost(text: String, isAnswerInFlight: Bool, isReadingAloud: Bool) -> CursorNotice {
        guard !isLost else { return .none }
        isLost = true
        if isAnswerInFlight || isReadingAloud {
            deferredCursorText = text
            return .deferred
        }
        return .showNow(text)
    }

    /// An answer or its reading changed state: returns the deferred notice once, when both are over.
    public mutating func answerActivityChanged(isAnswerInFlight: Bool, isReadingAloud: Bool) -> String? {
        guard let text = deferredCursorText, !isAnswerInFlight, !isReadingAloud else { return nil }
        deferredCursorText = nil
        return text
    }

    /// Another notice (a provider failure, the usage limit) took the cursor: the deferred one would replace it, so
    /// it goes. The panel, the chat and Settings still carry the loss.
    public mutating func cursorTakenByAnotherNotice() {
        deferredCursorText = nil
    }

    public mutating func sessionStarted() { self = KeyTapLossState() }

    public mutating func sessionStopped() { self = KeyTapLossState() }
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

    /// Whether Accessibility was taken away from the running app. `AXIsProcessTrusted()` is read once per process
    /// and keeps saying true after the switch is turned off (measured on the test Mac after `tccutil reset`), while
    /// a tap that removes events can no longer be made at once. A tap that only watches keeps working without
    /// Accessibility, so its keys are fine until a key change needs a removing tap; that swap reports the loss.
    public static func accessibilityEnded(
        wasTrusted: Bool, isTrusted: Bool, tapRemovesEvents: Bool, canMakeRemovingTap: Bool
    ) -> Bool {
        if wasTrusted && !isTrusted { return true }
        return tapRemovesEvents && !canMakeRemovingTap
    }

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
