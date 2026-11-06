import Testing
@testable import ClickyCore

/// When an answer makes the usage-limit offer stale, and the cursor notice wording.
struct UsageLimitOfferRulesTests {
    @Test func answerFromTheLimitedProviderClearsTheOffer() {
        #expect(UsageLimitOfferRules.answerClearsOffer(switchTarget: .chatgpt, answeredBy: .claude))
        #expect(UsageLimitOfferRules.answerClearsOffer(switchTarget: .claude, answeredBy: .chatgpt))
    }

    @Test func answerFromTheOfferedProviderKeepsTheOffer() {
        #expect(!UsageLimitOfferRules.answerClearsOffer(switchTarget: .chatgpt, answeredBy: .chatgpt))
    }

    @Test func noticeAddsAFullStopWhenTheMessageHasNone() {
        #expect(UsageLimitOfferRules.cursorNotice(message: "Claude hit its limit", switchToProviderName: "ChatGPT")
            == "Claude hit its limit. Switch to ChatGPT from the menu bar.")
    }

    @Test func noticeKeepsAnExistingEnding() {
        for ending in [".", "!", "?"] {
            #expect(UsageLimitOfferRules.cursorNotice(message: "Limit reached\(ending)", switchToProviderName: "ChatGPT")
                == "Limit reached\(ending) Switch to ChatGPT from the menu bar.")
        }
    }

    @Test func noticeIgnoresTrailingSpaces() {
        #expect(UsageLimitOfferRules.cursorNotice(message: "Limit reached  ", switchToProviderName: "Claude")
            == "Limit reached. Switch to Claude from the menu bar.")
    }
}
