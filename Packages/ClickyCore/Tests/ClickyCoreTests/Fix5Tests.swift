import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 5: the chat footer after the keys are lost, and two sentence-rule details.
@Suite("Fix wave 5")
struct Fix5Tests {
    // MARK: Footer

    @Test func footerSaysTheKeyStoppedWhileLost() {
        #expect(ChatFooter.idleLine(isKeyTapLost: true)
            == .plain("The question key stopped working: turn on Accessibility, then stop and start the session."))
    }

    @Test func footerShowsTheKeySentenceOtherwise() {
        #expect(ChatFooter.idleLine(isKeyTapLost: false) == .pressKeyToAsk)
    }

    // MARK: Sentence rule

    private func sentences(_ text: String) -> [String] {
        SpokenSentenceSplitter.sentences(in: text, isTextComplete: true)
    }

    @Test func butAfterAnEllipsisDoesNotSplit() {
        #expect(sentences("Hmm... But that is fine.") == ["Hmm... But that is fine."])
    }

    @Test func aSequenceWordAfterAnEllipsisStillSplits() {
        #expect(sentences("Wait... Then click Save.") == ["Wait...", "Then click Save."])
    }

    @Test func curlyApostropheOpenerSplitsLikeStraight() {
        #expect(sentences("Plan B. Let\u{2019}s go.") == ["Plan B.", "Let\u{2019}s go."])
        #expect(sentences("Wait... Let\u{2019}s go.") == ["Wait...", "Let\u{2019}s go."])
    }
}
