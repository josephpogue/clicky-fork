import Foundation

/// What the usage-limit "Switch to ..." button shows and whether it can be pressed.
public enum UsageLimitSwitchButtonState: Sendable, Equatable {
    case enabled
    /// A question is under way; a switch then does nothing.
    case waitsForAnswer
    /// A switch is already running; a second press would be dropped.
    case switching

    public var isEnabled: Bool { self == .enabled }

    public var caption: String? {
        switch self {
        case .enabled: return nil
        case .waitsForAnswer: return "Switch after this answer"
        case .switching: return "Switching..."
        }
    }
}

/// The small rules around the usage-limit offer.
public enum UsageLimitOfferRules {
    /// True when an answer from `answeredBy` makes the offer stale. The offer names the provider to switch
    /// to; an answer from any other provider (the one that hit the limit) means the limit has lifted.
    public static func answerClearsOffer(switchTarget: ProviderID, answeredBy: ProviderID) -> Bool {
        answeredBy != switchTarget
    }

    /// The one rule for both switch buttons (panel and chat window).
    public static func switchButtonState(isQuestionPhaseIdle: Bool, isSwitchInProgress: Bool) -> UsageLimitSwitchButtonState {
        if isSwitchInProgress { return .switching }
        return isQuestionPhaseIdle ? .enabled : .waitsForAnswer
    }

    /// The cursor notice for an offer: the limit message, ended with a full stop when it has none.
    public static func cursorNotice(message: String, switchToProviderName: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsSentence = trimmed.last.map { ".!?".contains($0) } ?? false
        let sentence = endsSentence ? trimmed : trimmed + "."
        return "\(sentence) Switch to \(switchToProviderName) from the menu bar."
    }
}
