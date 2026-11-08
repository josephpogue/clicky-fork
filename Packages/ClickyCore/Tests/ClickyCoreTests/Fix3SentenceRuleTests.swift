import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 3: a one-letter list label, an ellipsis before a pronoun and a "[Citation" never settle a fragment.
@Suite("Fix wave 3: sentence rule")
struct Fix3SentenceRuleTests {
    private func sentences(_ text: String) -> [String] {
        SpokenSentenceSplitter.sentences(in: text, isTextComplete: true)
    }

    /// Everything a stream hands out one character at a time, checking at every length that the settled prefix only
    /// grows and never ends in a one-letter label.
    private func streamed(_ text: String) -> [String] {
        var splitter = SpokenSentenceSplitter()
        var handedOut: [String] = []
        var characters = ""
        for character in text {
            characters.append(character)
            let fresh = splitter.newSentences(visibleTextSoFar: characters, isFinal: false)
            for sentence in fresh {
                let words = sentence.split(separator: " ")
                #expect(!(words.count == 1 && words[0].count == 2 && words[0].hasSuffix(".")
                          && words[0].first?.isUppercase == true), "fragment settled: \(sentence)")
            }
            handedOut += fresh
        }
        return handedOut
    }

    // MARK: 1. Lettered list labels

    @Test(arguments: [
        ("A. Click Save. B. Click Close.", ["A. Click Save.", "B. Click Close."]),
        ("Options: A. Use X, B. Use Y.", ["Options: A. Use X, B. Use Y."]),
        ("Do this. A. Click Save.", ["Do this.", "A. Click Save."]),
        ("- A. Click Save.\n- B. Click Close.", ["- A. Click Save.", "- B. Click Close."]),
        ("Steps:\nA. Click Save. Done.", ["Steps:\nA. Click Save.", "Done."]),
    ])
    func aLetterLabelIsNeverASentenceEnd(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
        let handedOut = streamed(text + " ")
        #expect(handedOut == Array(expected.dropLast()) || handedOut == expected)
    }

    @Test(arguments: [
        ("Use Plan B. Then click Save.", ["Use Plan B.", "Then click Save."]),
        ("Press A. Then press B.", ["Press A.", "Then press B."]),
        ("Use Plan B. Where is it?", ["Use Plan B.", "Where is it?"]),
    ])
    func aLetterAfterAWordStillEndsASentence(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
    }

    // MARK: 2. More openers

    @Test(arguments: ["Can", "Should", "Would", "Could", "Is", "Are", "Does", "What", "Why", "How", "Which", "Who",
                      "Where", "Just", "Each", "Every", "All", "Some", "For", "In", "On", "At", "To", "With", "Instead",
                      "Still", "Only", "Maybe", "Sure", "Hit", "Take", "Give", "Enable", "Disable", "Update", "Launch",
                      "Navigate", "Visit", "Download"])
    func theNewOpenersSettleAfterAnInitial(opener: String) {
        #expect(sentences("Use Plan B. \(opener) it now.") == ["Use Plan B.", "\(opener) it now."])
    }

    @Test(arguments: ["Ulysses S. Grant won.", "Ask Harry S. Will do it.", "Meet George W. Bush today.", "Go see Dan A. Head now."])
    func surnamesAreNotOpeners(text: String) {
        #expect(sentences(text) == [text])
    }

    // MARK: 3. Ellipsis

    @Test(arguments: [
        ("Hmm... I think so.", ["Hmm... I think so."]),
        ("Well... The answer is no.", ["Well... The answer is no."]),
        ("Hmm... It is fine.", ["Hmm... It is fine."]),
        ("Wait... Then click Save.", ["Wait...", "Then click Save."]),
        ("Hmm... Click Save now.", ["Hmm...", "Click Save now."]),
        ("Hmm\u{2026} I think so.", ["Hmm\u{2026} I think so."]),
    ])
    func anEllipsisBeforeAPronounOrArticleSettlesNothing(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
        let handedOut = streamed(text + " ")
        #expect(handedOut == Array(expected.dropLast()) || handedOut == expected)
    }

    // MARK: 4. Hidden marker start

    @Test(arguments: [("etc. [C", false), ("etc. [", false), ("etc. [Ci", false), ("etc. [Citation", false),
                      ("etc. [P", false), ("etc. [Pa", false), ("etc. [CH", true), ("etc. [CHA", true),
                      ("etc. [PO", true), ("etc. [POINT:1", true)])
    func aHiddenStartCountsOnlyOnceItMatchesThreeCharactersOfARealMarker(raw: String, expected: Bool) {
        #expect(StreamingAnswerText.visible(rawTextSoFar: raw).endsBeforeHiddenText == expected)
    }

    @Test func aTwoCharacterHiddenStartStillHoldsAnUnclearEnd() {
        var splitter = SpokenSentenceSplitter()
        let held = StreamingAnswerText.visible(rawTextSoFar: "Pick the red one, etc. [C")
        #expect(splitter.newSentences(visibleTextSoFar: held.visibleText, isFinal: held.endsBeforeHiddenText).isEmpty)
        let settled = StreamingAnswerText.visible(rawTextSoFar: "Pick the red one, etc. [CH")
        #expect(splitter.newSentences(visibleTextSoFar: settled.visibleText, isFinal: settled.endsBeforeHiddenText)
                == ["Pick the red one, etc."])
    }

    // MARK: Neighbouring states

    @Test func aClosingQuoteAfterALabelStaysWhole() {
        #expect(sentences("\"A. Click Save.\" Then wait.") == ["\"A. Click Save.\"", "Then wait."])
    }
}
