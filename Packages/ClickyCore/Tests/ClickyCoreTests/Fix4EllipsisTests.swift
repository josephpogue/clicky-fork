import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 4: after an ellipsis only a clear new-sentence word splits; any other word keeps the trailing-off thought whole.
@Suite("Fix wave 4: ellipsis")
struct Fix4EllipsisTests {
    private func sentences(_ text: String) -> [String] {
        SpokenSentenceSplitter.sentences(in: text, isTextComplete: true)
    }

    /// Everything a stream hands out one character at a time.
    private func streamed(_ text: String) -> [String] {
        var splitter = SpokenSentenceSplitter()
        var handedOut: [String] = []
        var characters = ""
        for character in text {
            characters.append(character)
            handedOut += splitter.newSentences(visibleTextSoFar: characters, isFinal: false)
        }
        return handedOut
    }

    @Test(arguments: [
        ("Hmm... If you want.", ["Hmm... If you want."]),
        ("Well... So it goes.", ["Well... So it goes."]),
        ("Hmm... When it works.", ["Hmm... When it works."]),
        ("Hmm... And then some.", ["Hmm... And then some."]),
        ("Hmm... Once more.", ["Hmm... Once more."]),
        ("Hmm... After lunch.", ["Hmm... After lunch."]),
        ("Hmm... Before that.", ["Hmm... Before that."]),
        ("Hmm... To be honest.", ["Hmm... To be honest."]),
        ("Hmm... In a way.", ["Hmm... In a way."]),
        ("Hmm... For now.", ["Hmm... For now."]),
        ("Hmm... With luck.", ["Hmm... With luck."]),
        ("Hmm... Maybe later.", ["Hmm... Maybe later."]),
        ("Hmm... What now?", ["Hmm... What now?"]),
        ("Hmm... Why not.", ["Hmm... Why not."]),
        ("Hmm... How so?", ["Hmm... How so?"]),
        ("Hmm... I think so.", ["Hmm... I think so."]),
        ("Hmm\u{2026} If you want.", ["Hmm\u{2026} If you want."]),
    ])
    func aWordThatCanContinueTheThoughtSettlesNothing(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
        #expect(streamed(text + " ").allSatisfy { expected.contains($0) })
    }

    @Test(arguments: [
        ("Wait... Then click Save.", ["Wait...", "Then click Save."]),
        ("Wait... Next, open it.", ["Wait...", "Next, open it."]),
        ("Hmm... Now click Save.", ["Hmm...", "Now click Save."]),
        ("Hmm... Also check it.", ["Hmm...", "Also check it."]),
        ("Hmm... But why.", ["Hmm...", "But why."]),
        ("Hmm... First, open it.", ["Hmm...", "First, open it."]),
        ("Hmm... Finally, save.", ["Hmm...", "Finally, save."]),
        ("Hmm... Otherwise stop.", ["Hmm...", "Otherwise stop."]),
        ("Hmm... However, it works.", ["Hmm...", "However, it works."]),
        ("Hmm... Click Save now.", ["Hmm...", "Click Save now."]),
        ("Hmm... Let's go.", ["Hmm...", "Let's go."]),
        ("Hmm... Please wait.", ["Hmm...", "Please wait."]),
        ("Hmm... Download it.", ["Hmm...", "Download it."]),
    ])
    func aClearNewSentenceWordStillSplits(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
    }

    @Test func noFragmentSettlesWhileStreaming() {
        for text in ["Hmm... If you want.", "Well... So it goes.", "Hmm... I think so."] {
            #expect(streamed(text + " ") == [text])
        }
        #expect(streamed("Wait... Then click Save. ") == ["Wait...", "Then click Save."])
    }
}
