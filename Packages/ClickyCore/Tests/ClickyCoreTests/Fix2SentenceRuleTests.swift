import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 2, item 3: a finished sentence shows (and is spoken) when it is finished, never later and never earlier.
@Suite("Fix wave 2: sentence rule")
struct Fix2SentenceRuleTests {
    private func sentences(_ text: String) -> [String] {
        SpokenSentenceSplitter.sentences(in: text, isTextComplete: true)
    }

    /// The sentences a stream would hand out while the text is still growing, fed one character at a time.
    private func streamedSentences(_ text: String) -> [String] {
        var splitter = SpokenSentenceSplitter()
        var handedOut: [String] = []
        var characters = ""
        for character in text {
            characters.append(character)
            handedOut += splitter.newSentences(visibleTextSoFar: characters, isFinal: false)
        }
        return handedOut
    }

    // MARK: A single capital letter

    @Test(arguments: [
        ("Use Plan B. Then click Save.", ["Use Plan B.", "Then click Save."]),
        ("Take Vitamin C. Next, drink water.", ["Take Vitamin C.", "Next, drink water."]),
        ("You do, and so do I. Then we agree.", ["You do, and so do I.", "Then we agree."]),
        ("Pick Option A. Click Save now.", ["Pick Option A.", "Click Save now."]),
        ("Choose Plan B. It is faster.", ["Choose Plan B.", "It is faster."]),
    ])
    func aSingleCapitalLetterEndsASentenceBeforeACommonOpener(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
        #expect(streamedSentences(text + " ").dropLast().map { $0 } == Array(expected.dropLast()))
    }

    @Test(arguments: [
        "John F. Kennedy was here.", "J. R. R. Tolkien wrote it.", "Ask Harry S. Truman about it.",
        "Mr. J. A. Smith signed it.", "Meet George W. Bush today.",
    ])
    func aSingleCapitalLetterInANameStaysWhole(text: String) {
        #expect(sentences(text) == [text])
        #expect(streamedSentences(text + " ").isEmpty || streamedSentences(text + " ") == [text])
    }

    @Test func aSingleCapitalLetterWaitsForTheNextWordWhileItIsStillBeingWritten() {
        // "I" is an opener, but the word may still be "Indiana": nothing splits until the word is closed.
        #expect(streamedSentences("Franklin D. I").isEmpty)
        #expect(streamedSentences("Use Plan B. Th").isEmpty)
        #expect(streamedSentences("Use Plan B. ").isEmpty)
        #expect(streamedSentences("Use Plan B. Then ") == ["Use Plan B."])
    }

    @Test func aSingleCapitalLetterEndsTheTextWhenNothingCanFollow() {
        #expect(SentenceRule.endsSentence(at: 10, in: Array("Use Plan B. "), isTextComplete: true))
        #expect(!SentenceRule.endsSentence(at: 10, in: Array("Use Plan B. "), isTextComplete: false))
    }

    // MARK: Ellipsis

    @Test func anEllipsisFollowedByLowercaseStaysInOneSentence() {
        #expect(sentences("Hmm... okay, click Save.") == ["Hmm... okay, click Save."])
        #expect(sentences("Hmm\u{2026} okay, click Save.") == ["Hmm\u{2026} okay, click Save."])
    }

    @Test func anEllipsisBeforeAnOpenerEndsTheSentenceAfterTheDots() {
        #expect(sentences("Wait... Then click Save.") == ["Wait...", "Then click Save."])
        #expect(sentences("Wait\u{2026} Then click Save.") == ["Wait\u{2026}", "Then click Save."])
    }

    @Test func theEndIsNeverInsideARunOfDots() {
        let text = Array("Wait... Then")
        // The first and second dots are followed by a dot, not whitespace.
        #expect(!SentenceRule.endsSentence(at: 4, in: text))
        #expect(!SentenceRule.endsSentence(at: 5, in: text))
        #expect(streamedSentences("Wait.. ").isEmpty)
        #expect(streamedSentences("Wait... Then ") == ["Wait..."])
    }

    // MARK: Closing quote or bracket

    @Test(arguments: [
        ("Press \"Go.\" Then wait.", ["Press \"Go.\"", "Then wait."]),
        ("Press 'Go.' Then wait.", ["Press 'Go.'", "Then wait."]),
        ("Press \u{201C}Go.\u{201D} Then wait.", ["Press \u{201C}Go.\u{201D}", "Then wait."]),
        ("Press \u{2018}Go.\u{2019} Then wait.", ["Press \u{2018}Go.\u{2019}", "Then wait."]),
        ("Press \u{00AB}Go.\u{00BB} Then wait.", ["Press \u{00AB}Go.\u{00BB}", "Then wait."]),
        ("(See the menu.) Next, click Save.", ["(See the menu.)", "Next, click Save."]),
        ("Click Save [see the menu.] Next, relax.", ["Click Save [see the menu.]", "Next, relax."]),
        ("Is it \"Go?\" Then wait.", ["Is it \"Go?\"", "Then wait."]),
    ])
    func aClosingQuoteOrBracketStaysWithTheSentenceItCloses(text: String, expected: [String]) {
        #expect(sentences(text) == expected)
    }

    @Test func aQuotedSentenceInTheMiddleOfAnotherStaysWhole() {
        #expect(sentences("He said \"Stop.\" and left.") == ["He said \"Stop.\" and left."])
    }

    @Test func aClosingQuoteWaitsForTheNextWordWhileTheTextCanGrow() {
        #expect(streamedSentences("Press \"Go.\" ").isEmpty)
        #expect(streamedSentences("Press \"Go.\" T").isEmpty == false)
    }

    // MARK: Text before the point tag or the chat marker

    @Test(arguments: ["[POINT:none]", "[POINT:12,30:save button]", "[POINT:12", "[POI", "[CH", "[CHAT]"])
    func anAmbiguousEndBeforeAHiddenTagOrMarkerIsFinishedAtOnce(hidden: String) {
        var replay = AnswerReplay()
        replay.delta("Use the files, etc. " + hidden)
        #expect(replay.shownLine == CursorLine(text: "Use the files, etc.", hasMoreInChat: hidden == "[CHAT]"))
        #expect(replay.spoken == ["Use the files, etc."])
    }

    @Test func aChatMarkerAfterEtcShowsTheSentenceAtOnceEvenWithTextAfterIt() {
        var replay = AnswerReplay()
        replay.delta("Use the files, etc. [CHAT] more")
        #expect(replay.shownLine == CursorLine(text: "Use the files, etc.", hasMoreInChat: true))
    }

    /// A lone "[" may be the start of ordinary text ("[1]"), so an end that needs the next word stays whole until
    /// the next character says more. A sentence end that needs no next word still shows at once (wave 1).
    @Test func aLoneOpeningBracketDoesNotSettleAnAmbiguousEnd() {
        var replay = AnswerReplay()
        replay.delta("Use the files, etc. [")
        #expect(replay.shownLine == nil)
        replay.delta("P")
        #expect(replay.shownLine == CursorLine(text: "Use the files, etc.", hasMoreInChat: false))
        var plain = AnswerReplay()
        plain.delta("Click the Save button. [")
        #expect(plain.shownLine == CursorLine(text: "Click the Save button.", hasMoreInChat: false))
    }

    @Test func aSingleCapitalEndBeforeAHiddenTagIsFinishedAtOnce() {
        var replay = AnswerReplay()
        replay.delta("Use Plan B. [POINT:none]")
        #expect(replay.shownLine == CursorLine(text: "Use Plan B.", hasMoreInChat: false))
    }

    @Test func aClosingQuoteBeforeAHiddenTagIsFinishedAtOnce() {
        var replay = AnswerReplay()
        replay.delta("Press \"Go.\" [POINT:none]")
        #expect(replay.shownLine == CursorLine(text: "Press \"Go.\"", hasMoreInChat: false))
    }

    // MARK: No false splits

    @Test(arguments: [
        "Version 3.5 is out.", "Install v1.2.3 now.", "Edit demo-server.md first.", "Open https://example.com/a.b/c now.",
        "Use a tool, e.g. a hammer, today.", "Use this one, i.e. the red one.", "Ask Dr. Lee about it.",
        "Ask Mr. Smith or Mrs. Jones or Ms. Park.", "Go to St. Louis today.", "Compare A vs. B today.",
        "Open the U.S. site now.", "It costs 3.5 dollars.", "Visit www.example.com for more.",
    ])
    func noFalseSplitOnDecimalsVersionsFilesUrlsOrAbbreviations(text: String) {
        #expect(sentences(text) == [text])
        #expect(streamedSentences(text + " ").isEmpty || streamedSentences(text + " ") == [text])
    }

    @Test func etcStillEndsBeforeACapitalWord() {
        #expect(sentences("Bring pens, paper, etc. Then go.") == ["Bring pens, paper, etc.", "Then go."])
        #expect(sentences("Bring pens, paper, etc. and tape.") == ["Bring pens, paper, etc. and tape."])
    }
}
