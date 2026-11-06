import Testing
@testable import ClickyCore

@Suite("Spoken sentence splitter at a tool call")
struct SpokenSentenceSplitterToolCallTests {
    @Test func trailingSentenceIsSpokenWhenAToolCallStarts() {
        var splitter = SpokenSentenceSplitter()
        #expect(splitter.newSentences(visibleTextSoFar: "Let me check your notes.", isFinal: false) == [])
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Let me check your notes.") == ["Let me check your notes."])
        // Later text continues after the sentence already spoken.
        #expect(splitter.newSentences(visibleTextSoFar: "Let me check your notes. Found it. The port", isFinal: false) == ["Found it."])
    }

    @Test func toolCallAlsoSpeaksEarlierCompleteSentencesAndTheTrailingOne() {
        var splitter = SpokenSentenceSplitter()
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Sure. Looking now!") == ["Sure.", "Looking now!"])
    }

    @Test func unfinishedTrailingTextStaysUnspokenAtAToolCall() {
        var splitter = SpokenSentenceSplitter()
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Version 4.4") == [])
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Let me check") == [])
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "") == [])
    }

    @Test func anAbbreviationAtTheEndIsNotASentence() {
        var splitter = SpokenSentenceSplitter()
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Rooms, e.g.") == [])
    }

    @Test func aSecondToolCallDoesNotRepeatTheSentence() {
        var splitter = SpokenSentenceSplitter()
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Checking.") == ["Checking."])
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Checking.") == [])
        #expect(splitter.newSentencesAtToolCall(visibleTextSoFar: "Checking. More") == [])
    }
}
