import Foundation

/// The small rules around the usage-limit offer.
public enum UsageLimitOfferRules {
    /// True when an answer from `answeredBy` makes the offer stale. The offer names the provider to switch
    /// to; an answer from any other provider (the one that hit the limit) means the limit has lifted.
    public static func answerClearsOffer(switchTarget: ProviderID, answeredBy: ProviderID) -> Bool {
        answeredBy != switchTarget
    }

    /// The cursor notice for an offer: the limit message, ended with a full stop when it has none.
    public static func cursorNotice(message: String, switchToProviderName: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsSentence = trimmed.last.map { ".!?".contains($0) } ?? false
        let sentence = endsSentence ? trimmed : trimmed + "."
        return "\(sentence) Switch to \(switchToProviderName) from the menu bar."
    }
}
