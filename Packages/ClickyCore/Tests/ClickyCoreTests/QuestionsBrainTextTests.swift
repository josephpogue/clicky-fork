import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

@Suite("Brain passages note")
struct QuestionsBrainPassageNoteTests {
    @Test func noPassagesGiveAnEmptyNote() {
        #expect(BrainPassageNote.text(for: []) == "")
    }

    @Test func passagesRenderExactly() {
        let passages = [
            BrainPassage(path: "/b/Wiki/Projects/demo-server.md", heading: "Ports", startLine: 3, endLine: 5,
                         text: "The demo server listens on port 4417.\n\n", score: 2),
            BrainPassage(path: "/b/notes.txt", heading: nil, startLine: 1, endLine: 2,
                         text: "Run make test before a PR.", score: 1),
        ]
        let expected = """
        Notes from the user's own files that may help. Use them only where they answer the question:

        File: /b/Wiki/Projects/demo-server.md lines 3-5
        Heading: Ports
        The demo server listens on port 4417.

        File: /b/notes.txt lines 1-2
        Run make test before a PR.
        """
        #expect(BrainPassageNote.text(for: passages) == expected)
    }
}

@Suite("Answer instructions with brain access")
struct QuestionsBrainInstructionsTests {
    @Test func offIsTheStaticText() {
        #expect(AnswerInstructions.questionInstructions(brainAccess: .off) == AnswerInstructions.questionInstructions)
    }

    @Test func passagesOnlyHasNotesButNoTools() {
        let text = AnswerInstructions.questionInstructions(brainAccess: .passagesOnly)
        #expect(text.contains("Notes:"))
        #expect(text.lowercased().contains("never state a guess as fact"))
        #expect(text.lowercased().contains("never put file paths or file names"))
        #expect(text.contains("do not cover it"))
        #expect(!text.contains("search_brain"))
        #expect(!text.contains("read_brain_file"))
        #expect(text.range(of: "Notes:")!.lowerBound < text.range(of: "Images:")!.lowerBound)
    }

    @Test func passagesAndToolsNamesToolsAndCorrections() {
        let text = AnswerInstructions.questionInstructions(brainAccess: .passagesAndTools(mapPaths: []))
        #expect(text.contains("search_brain"))
        #expect(text.contains("read_brain_file"))
        #expect(text.contains("Correction:"))
        #expect(text.contains("Let me check your notes for the demo port."))
        #expect(text.contains("dig deeper"))
        #expect(text.lowercased().contains("never state a guess as fact"))
        #expect(!text.contains("read these map files"))
    }

    @Test func mapPathsAreListedAsGiven() {
        let text = AnswerInstructions.questionInstructions(
            brainAccess: .passagesAndTools(mapPaths: ["/b/index.md", "/b/Wiki/map.md"])
        )
        #expect(text.contains("When the notes given do not cover the question, read these map files first: /b/index.md, /b/Wiki/map.md."))
    }

    @Test func pointingRulesFollowTheBrainAccess() {
        let withTools = AnswerInstructions.questionInstructions(brainAccess: .passagesAndTools(mapPaths: []))
        #expect(withTools.contains("[POINT:none]"))
        #expect(withTools.contains("at the end of the answer"))
        #expect(!withTools.contains("at the very end of your answer"))
        #expect(AnswerInstructions.questionInstructions.contains("at the very end of your answer"))
    }
}

@Suite("Dig deeper matcher")
struct QuestionsDigDeeperMatcherTests {
    @Test(arguments: [
        ("Dig deeper.", ""),
        ("dig deeper, what port does it use?", "what port does it use?"),
        ("Okay, dig deeper into the build script", "the build script"),
        ("Can you dig a little deeper on that", "that"),
        ("Big deeper.", ""),
        ("  ...So, please dig-deeper", ""),
        ("digdeeper on ports", "ports"),
        ("Dug deeper: why?", "why?"),
        ("dig in deeper", ""),
        ("could you, ok dig dipper", ""),
    ])
    func matches(transcript: String, remaining: String) {
        #expect(DigDeeperMatcher.match(transcript)?.remainingWords == remaining)
    }

    @Test(arguments: ["I want to dig deeper later", "digging deeper", "Dig deepest", "dig", ""])
    func doesNotMatch(transcript: String) {
        #expect(DigDeeperMatcher.match(transcript) == nil)
    }
}

@Suite("Checking notes rule")
struct QuestionsCheckingNotesRuleTests {
    @Test func firstToolCallShowsTheLine() {
        var rule = CheckingNotesRule()
        let outcome1 = rule.toolCallStarted(visibleTextSoFar: "")
        #expect(outcome1)
        #expect(CheckingNotesRule.lineText == "Checking your notes")
    }

    @Test func secondCallWithNoNewTextDoesNot() {
        var rule = CheckingNotesRule()
        let outcome2 = rule.toolCallStarted(visibleTextSoFar: "")
        #expect(outcome2)
        let outcome3 = rule.toolCallStarted(visibleTextSoFar: "")
        #expect(!outcome3)
    }

    @Test func aSentenceThatSaysCheckingSuppressesIt() {
        var rule = CheckingNotesRule()
        rule.textChanged(visibleTextSoFar: "Let me check your notes for the port.")
        let outcome4 = rule.toolCallStarted(visibleTextSoFar: "Let me check your notes for the port.")
        #expect(!outcome4)
    }

    @Test func otherTextStillShowsIt() {
        var rule = CheckingNotesRule()
        rule.textChanged(visibleTextSoFar: "The build runs from Xcode.")
        let outcome5 = rule.toolCallStarted(visibleTextSoFar: "The build runs from Xcode.")
        #expect(outcome5)
    }

    @Test func newTextAfterAShownLineAllowsAnother() {
        var rule = CheckingNotesRule()
        let outcome6 = rule.toolCallStarted(visibleTextSoFar: "")
        #expect(outcome6)
        rule.textChanged(visibleTextSoFar: "Found it.")
        let outcome7 = rule.toolCallStarted(visibleTextSoFar: "Found it.")
        #expect(outcome7)
    }

    @Test func onlyTheTextSinceTheLastToolCallCounts() {
        var rule = CheckingNotesRule()
        // The earlier sentence says "checking"; the new one after the call does not.
        let outcome8 = rule.toolCallStarted(visibleTextSoFar: "I am checking.")
        #expect(!outcome8)
        rule.textChanged(visibleTextSoFar: "I am checking. The port is 4417.")
        let outcome9 = rule.toolCallStarted(visibleTextSoFar: "I am checking. The port is 4417.")
        #expect(outcome9)
    }

    @Test func wholeWordsOnly() {
        var rule = CheckingNotesRule()
        let outcome10 = rule.toolCallStarted(visibleTextSoFar: "The lookup table is on screen.")
        #expect(outcome10)
    }
}

@Suite("Streaming answer text")
struct QuestionsStreamingAnswerTextTests {
    @Test func incompleteTagIsHidden() {
        #expect(StreamingAnswerText.visible(rawTextSoFar: "The port is 4417. [POI").visibleText == "The port is 4417. ")
    }

    @Test(arguments: ["[", "[P", "[PO", "[POINT", "[POINT:", "[POINT:12,3", "[POINT:12,30:gear"])
    func everyTagPrefixIsHidden(suffix: String) {
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Hello. " + suffix).visibleText == "Hello. ")
    }

    @Test func completeTagIsRemovedAndReported() {
        let view = StreamingAnswerText.visible(rawTextSoFar: "Open Settings [POINT:10,20:gear:screen1] then")
        #expect(view.visibleText == "Open Settings then")
        #expect(view.firstCompletePoint?.coordinate == CGPoint(x: 10, y: 20))
        #expect(view.firstCompletePoint?.label == "gear")
        #expect(view.firstCompletePoint?.screenNumber == 1)
    }

    @Test func noneTagIsRemovedWithoutAPoint() {
        let view = StreamingAnswerText.visible(rawTextSoFar: "a [POINT:none] b")
        #expect(view.visibleText == "a b")
        #expect(view.firstCompletePoint == nil)
    }

    @Test func ordinaryBracketsStay() {
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Use [brackets] here").visibleText == "Use [brackets] here")
        #expect(StreamingAnswerText.visible(rawTextSoFar: "x [").visibleText == "x")
    }

    @Test func firstPointWinsAmongTwo() {
        let view = StreamingAnswerText.visible(rawTextSoFar: "A [POINT:1,2:a:screen1] B [POINT:3,4:b:screen1]")
        #expect(view.firstCompletePoint?.coordinate == CGPoint(x: 1, y: 2))
    }
}

@Suite("Spoken sentence splitter")
struct QuestionsSpokenSentenceSplitterTests {
    @Test func returnsOnlyNewCompleteSentences() {
        var splitter = SpokenSentenceSplitter()
        let outcome11 = splitter.newSentences(visibleTextSoFar: "Hi there. The po", isFinal: false)
        #expect(outcome11 == ["Hi there."])
        let outcome12 = splitter.newSentences(visibleTextSoFar: "Hi there. The port is 4417. And", isFinal: false)
        #expect(outcome12 == ["The port is 4417."])
        let outcome13 = splitter.newSentences(visibleTextSoFar: "Hi there. The port is 4417. And done", isFinal: true)
        #expect(outcome13 == ["And done"])
    }

    @Test func decimalsAndVersionsDoNotEndASentence() {
        var splitter = SpokenSentenceSplitter()
        let outcome14 = splitter.newSentences(visibleTextSoFar: "Version 4.4 works. Yes", isFinal: false)
        #expect(outcome14 == ["Version 4.4 works."])
        var versionSplitter = SpokenSentenceSplitter()
        let outcome15 = versionSplitter.newSentences(visibleTextSoFar: "Use v1.2.3 now. Ok", isFinal: false)
        #expect(outcome15 == ["Use v1.2.3 now."])
    }

    @Test func questionAndExclamationEndSentences() {
        var splitter = SpokenSentenceSplitter()
        let outcome16 = splitter.newSentences(visibleTextSoFar: "Really? Yes! Maybe", isFinal: false)
        #expect(outcome16 == ["Really?", "Yes!"])
    }

    @Test func finalFlushesATrailingSentenceOnce() {
        var splitter = SpokenSentenceSplitter()
        let outcome17 = splitter.newSentences(visibleTextSoFar: "One. Two.", isFinal: true)
        #expect(outcome17 == ["One.", "Two."])
        let outcome18 = splitter.newSentences(visibleTextSoFar: "One. Two.", isFinal: true)
        #expect(outcome18 == [])
    }

    @Test func aRewriteBeforeTheSpokenPartSpeaksOnlyTheUnspokenSuffix() {
        var splitter = SpokenSentenceSplitter()
        let outcome19 = splitter.newSentences(visibleTextSoFar: "Hello there. Next", isFinal: false)
        #expect(outcome19 == ["Hello there."])
        // The earlier words were rewritten; only what comes after the already spoken length is new.
        let rewritten = splitter.newSentences(visibleTextSoFar: "Hi all. Next one. More", isFinal: false)
        #expect(rewritten == ["one."])
    }

    @Test func shrinkingTextSpeaksNothingNew() {
        var splitter = SpokenSentenceSplitter()
        _ = splitter.newSentences(visibleTextSoFar: "One. Two. Three", isFinal: false)
        let outcome20 = splitter.newSentences(visibleTextSoFar: "One.", isFinal: false)
        #expect(outcome20 == [])
    }
}

@Suite("Conversation budget characters")
struct QuestionsConversationBudgetCharacterTests {
    @Test func limitIsOneHundredSixtyThousand() {
        #expect(ConversationBudget.maximumAttachedCharacters == 160_000)
    }

    @Test func oldCallersStillCompileAndAddNoCharacters() {
        var budget = ConversationBudget()
        budget.recordTurn(imageCount: 2)
        #expect(budget.attachedCharactersSent == 0)
        #expect(!budget.shouldStartFresh)
    }

    @Test func charactersAccumulateAndTriggerAFreshStart() {
        var budget = ConversationBudget()
        budget.recordTurn(imageCount: 1, attachedCharacterCount: 100_000)
        #expect(budget.attachedCharactersSent == 100_000)
        #expect(!budget.shouldStartFresh)
        budget.recordTurn(imageCount: 1, attachedCharacterCount: 60_000)
        #expect(budget.shouldStartFresh)
    }

    @Test func resetClearsCharacters() {
        var budget = ConversationBudget()
        budget.recordTurn(imageCount: 0, attachedCharacterCount: 200_000)
        budget.reset()
        #expect(budget.attachedCharactersSent == 0)
        #expect(!budget.shouldStartFresh)
    }
}
