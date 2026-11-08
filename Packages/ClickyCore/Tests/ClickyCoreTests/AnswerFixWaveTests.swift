import Foundation
import Testing
@testable import ClickyCore

/// Feeds a streamed answer through the visible-text rule, the parts tracker and the cursor line together, the way
/// the coordinator does, and records everything shown and spoken.
private struct AnswerStreamRun {
    var tracker = AnswerPartsTracker()
    var state = CursorLineState()
    var spoken: [String] = []
    var lines: [CursorLine] = []
    var fitsCalls = 0
    var limit = 60

    mutating func raw(_ text: String) {
        tracker.textReported(StreamingAnswerText.visible(rawTextSoFar: text).visibleText)
        refresh()
    }

    mutating func toolCall() {
        tracker.toolCallStarted()
        refresh()
    }

    mutating func final(_ rawText: String) {
        tracker.finalReported(PointTagParser.parse(rawText).spokenText)
        refresh()
    }

    mutating func refresh() {
        var calls = 0
        let limit = limit
        let update = state.update(parts: tracker.parts, fits: { calls += 1; return $0.count <= limit })
        fitsCalls += calls
        spoken += update.newSentencesToSpeak
        if let line = update.line { lines.append(line) }
    }
}

@Suite("Answer fix wave")
struct AnswerFixWaveTests {
    private func line(_ text: String, hasMore: Bool = false) -> CursorLine { CursorLine(text: text, hasMoreInChat: hasMore) }

    // MARK: 1. The bubble does not come back after a click at a tool call

    @Test func aClickedAwayBubbleStaysHiddenWhenTheToolCallCompletesTheOldPartsLastSentence() {
        var run = AnswerStreamRun()
        var bubble = GrowingAnswerBubbleState()
        run.raw("Let me check the notes. Hang on")
        _ = bubble.lineReported(run.lines.last!)
        bubble.userDismissed()
        run.raw("Let me check the notes. Hang on for the demo port.")
        // The coordinator's order at a tool call: the line first, then the note.
        run.toolCall()
        #expect(run.lines.last == line("Let me check the notes. Hang on for the demo port."))
        #expect(bubble.lineReported(run.lines.last!) == .nothing)
        bubble.toolCallStartedReported()
        // The next part's text is the new finding and brings the bubble back with that part only.
        run.raw("Let me check the notes. Hang on for the demo port. Your notes say 4417. Next")
        #expect(run.lines.last == line("Your notes say 4417."))
        #expect(bubble.lineReported(run.lines.last!) == .show(line: line("Your notes say 4417."), showsCheckingLine: false))
    }

    @Test func withoutAClickTheLineStillGrowsAtTheToolCall() {
        var run = AnswerStreamRun()
        var bubble = GrowingAnswerBubbleState()
        run.raw("Let me check the notes. Hang on")
        _ = bubble.lineReported(run.lines.last!)
        run.raw("Let me check the notes. Hang on for the demo port.")
        run.toolCall()
        #expect(bubble.lineReported(run.lines.last!) == .update(
            line: line("Let me check the notes. Hang on for the demo port."), showsCheckingLine: false))
    }

    @Test func aClickWithNoToolCallKeepsTheBubbleHiddenAsTheTextGrows() {
        var run = AnswerStreamRun()
        var bubble = GrowingAnswerBubbleState()
        run.raw("Click Save. Then")
        _ = bubble.lineReported(run.lines.last!)
        bubble.userDismissed()
        run.raw("Click Save. Then press Done. And")
        #expect(bubble.lineReported(run.lines.last!) == .nothing)
    }

    // MARK: 2. Unstable leading whitespace

    @Test func visibleTextNeverStartsWithWhitespaceAndOnlyGrowsAtItsEnd() {
        let raw = " \n Let me check your notes. Your notes say 80. [POINT:none]"
        var previous = ""
        var length = 1
        while length <= raw.count {
            let visible = StreamingAnswerText.visible(rawTextSoFar: String(raw.prefix(length))).visibleText
            #expect(visible.first?.isWhitespace != true)
            let previousTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(visible.hasPrefix(previousTrimmed))
            previous = visible
            length += 1
        }
    }

    @Test func aStreamThatStartsWithASpaceKeepsItsPartsAndSpeaksNothingTwice() {
        var run = AnswerStreamRun()
        run.raw(" Let me check your notes.")
        run.toolCall()
        run.raw(" Let me check your notes. Your")
        run.raw(" Let me check your notes. Your notes say 80. ")
        run.final(" Let me check your notes. Your notes say 80. [POINT:none]")
        #expect(run.tracker.parts.map(\.cursorText) == ["Let me check your notes.", "Your notes say 80."])
        #expect(run.spoken == ["Let me check your notes.", "Your notes say 80."])
    }

    @Test func aFinalTextWithDifferentWhitespaceKeepsTheToolCallBoundary() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me check your notes. ")
        tracker.toolCallStarted()
        tracker.finalReported("Let me check your notes.\n\nYour notes say 80.")
        #expect(tracker.parts.map(\.cursorText) == ["Let me check your notes.", "Your notes say 80."])
    }

    @Test func aFinalTextThatChangedBeforeTheBoundaryDropsIt() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me check your notes.")
        tracker.toolCallStarted()
        tracker.finalReported("Looking at something else. Your notes say 80.")
        #expect(tracker.parts.map(\.cursorText) == ["Looking at something else. Your notes say 80."])
    }

    // MARK: 3. A one-sentence answer shows at once

    @Test(arguments: ["[", "[POI", "[POINT:12", "[POINT:12,30:save button]", "[CH"])
    func aSentenceBeforeAHiddenTagOrMarkerShowsAndSpeaksAtOnce(hidden: String) {
        var run = AnswerStreamRun()
        run.raw("Click the Save button at the top right. " + hidden)
        #expect(run.lines == [line("Click the Save button at the top right.")])
        #expect(run.spoken == ["Click the Save button at the top right."])
        run.final("Click the Save button at the top right. [POINT:12,30:save button]")
        #expect(run.spoken == ["Click the Save button at the top right."])
    }

    // MARK: 4. "Checking your notes" never stays on a finished answer

    @Test func theFinalAnswerClearsTheCheckingLineWhenTheLineIsUnchanged() {
        var bubble = GrowingAnswerBubbleState()
        _ = bubble.lineReported(line("Let me check."))
        _ = bubble.checkingLineReported()
        #expect(bubble.answerFinished() == .update(line: line("Let me check."), showsCheckingLine: false))
        #expect(bubble.answerFinished() == .nothing)
    }

    @Test func theFinalAnswerClearsTheCheckingLineOnAFooterOnlyBubble() {
        var bubble = GrowingAnswerBubbleState()
        _ = bubble.lineReported(line("", hasMore: true))
        _ = bubble.checkingLineReported()
        #expect(bubble.answerFinished() == .update(line: line("", hasMore: true), showsCheckingLine: false))
    }

    @Test func theFinalAnswerLeavesADismissedOrCheckingFreeBubbleAlone() {
        var bubble = GrowingAnswerBubbleState()
        _ = bubble.lineReported(line("Done."))
        #expect(bubble.answerFinished() == .nothing)
        _ = bubble.checkingLineReported()
        bubble.userDismissed()
        #expect(bubble.answerFinished() == .nothing)
    }

    // MARK: 5. A footer-only answer is spoken as "in the chat"

    @Test func aFooterOnlyLineSpeaksTheAnswerIsInTheChatOnce() {
        var state = CursorLineState()
        let parts = [AnswerPart(
            cursorText: "A very long first sentence that cannot fit in the small test bubble at all.",
            chatText: "The full explanation.", hasChatMarker: true, isCursorTextComplete: true)]
        let first = state.update(parts: parts, fits: { $0.count <= 20 })
        #expect(first.line == line("", hasMore: true))
        #expect(first.newSentencesToSpeak == ["The answer is in the chat."])
        let second = state.update(parts: parts, fits: { $0.count <= 20 })
        #expect(second.newSentencesToSpeak == [])
    }

    @Test func aMarkerWithNoCursorTextSpeaksTheAnswerIsInTheChatAndNeverTheChatText() {
        var state = CursorLineState()
        let update = state.update(
            parts: [AnswerPart(cursorText: "", chatText: "Secret chat words.", hasChatMarker: true, isCursorTextComplete: true)],
            fits: { _ in true })
        #expect(update.newSentencesToSpeak == ["The answer is in the chat."])
    }

    // MARK: 6. Replaced text

    @Test func aPartWhoseTextIsReplacedSpeaksTheReplacingText() {
        var state = CursorLineState()
        func part(_ text: String) -> [AnswerPart] {
            [AnswerPart(cursorText: text, chatText: "", hasChatMarker: false, isCursorTextComplete: true)]
        }
        #expect(state.update(parts: part("First message here."), fits: { _ in true }).newSentencesToSpeak == ["First message here."])
        let replaced = state.update(parts: part("Second message differs. And has more."), fits: { _ in true })
        #expect(replaced.newSentencesToSpeak == ["Second message differs.", "And has more."])
        #expect(state.update(parts: part("Second message differs. And has more."), fits: { _ in true }).newSentencesToSpeak == [])
    }

    @Test func aReplacingMessageThatStartsTheSameWayOnlySpeaksWhatIsNew() {
        var state = CursorLineState()
        func part(_ text: String) -> [AnswerPart] {
            [AnswerPart(cursorText: text, chatText: "", hasChatMarker: false, isCursorTextComplete: true)]
        }
        _ = state.update(parts: part("Same start."), fits: { _ in true })
        #expect(state.update(parts: part("Same start. Then more."), fits: { _ in true }).newSentencesToSpeak == ["Then more."])
    }

    @Test func replacedTextDropsToolCallBoundariesBeyondTheNewText() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me look at it now.")
        tracker.toolCallStarted()
        tracker.textReported("A different reply.")
        #expect(tracker.parts == [AnswerPart(
            cursorText: "A different reply.", chatText: "", hasChatMarker: false, isCursorTextComplete: false)])
    }

    // MARK: 7. Measuring cost

    @Test func chatTextAndHalfWrittenSentencesCauseNoMeasuring() {
        var state = CursorLineState()
        var calls = 0
        func update(_ cursorText: String, chat: String) {
            _ = state.update(
                parts: [AnswerPart(cursorText: cursorText, chatText: chat, hasChatMarker: true, isCursorTextComplete: false)],
                fits: { calls += 1; return $0.count <= 100 })
        }
        update("One whole sentence. Two", chat: "")
        let afterFirst = calls
        #expect(afterFirst > 0)
        update("One whole sentence. Two w", chat: "")
        var chat = ""
        for _ in 0..<50 {
            chat += "more chat words "
            update("One whole sentence. Two w", chat: chat)
        }
        #expect(calls == afterFirst)
        update("One whole sentence. Two words. Th", chat: chat)
        #expect(calls > afterFirst)
    }

    // MARK: 8. Abbreviations

    @Test(arguments: [
        "Open the U.S. site and sign in.", "Ask Dr. Lee about it.", "Mr. Smith, Mrs. Jones and Ms. Park met.",
        "Go to St. Louis today.", "Compare A vs. B today.", "Bring pens, paper, etc. and tape.",
        "Ask J. Smith about it.", "Use a tool, e.g. a hammer, or i.e. this one.",
    ])
    func anAbbreviationDoesNotEndASentence(text: String) {
        #expect(SpokenSentenceSplitter.sentences(in: text, isTextComplete: true) == [text])
        var tracker = AnswerPartsTracker()
        tracker.textReported(text + " Correction: no.")
        #expect(tracker.parts.count == 2)
    }

    @Test func etcFollowedByACapitalisedWordMayEndASentence() {
        #expect(SpokenSentenceSplitter.sentences(in: "Bring pens, paper, etc. Then go.", isTextComplete: true)
            == ["Bring pens, paper, etc.", "Then go."])
    }

    @Test func listNumeralsDoNotEndSentences() {
        #expect(SpokenSentenceSplitter.sentences(in: "1. Open the file.\n2. Close it.", isTextComplete: true)
            == ["1. Open the file.", "2. Close it."])
        #expect(SpokenSentenceSplitter.sentences(in: "Open it. 2. Close it.", isTextComplete: true)
            == ["Open it.", "2. Close it."])
        #expect(SpokenSentenceSplitter.sentences(in: "It is version 2. Done now.", isTextComplete: true)
            == ["It is version 2.", "Done now."])
    }

    @Test func aBubbleNeverStopsAfterAnAbbreviation() {
        var state = CursorLineState()
        let update = state.update(
            parts: [AnswerPart(cursorText: "Open the U.S. site now.", chatText: "", hasChatMarker: false, isCursorTextComplete: false)],
            fits: { _ in true })
        #expect(update.line == nil)
    }

    // MARK: 9. Half-written marker or tag in logs

    private func logEvents(_ answerText: String) -> [SessionEvent] {
        [SessionEvent(time: Date(timeIntervalSince1970: 1_700_000_100), kind: .answer(
            text: answerText, provider: .claude, model: "sonnet", secondsToAnswer: 2.0, pointLabel: nil))]
    }

    @Test(arguments: ["Your notes say 80. [CH", "Your notes say 80. [POINT:12", "Your notes say 80. [", "Your notes say 80. [POINT"])
    func aCutShortAnswerShowsNoHalfMarkerInTheLogTheSummaryOrTheTimeline(rawText: String) {
        let events = logEvents(rawText)
        let summary = SessionSummaryInput.text(events: events, timeZone: TimeZone(identifier: "UTC")!)
        #expect(summary.hasSuffix("Answer: Your notes say 80."))
        let metadata = SessionMetadata(
            id: "x", startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: Date(timeIntervalSince1970: 1_700_000_200),
            summary: nil, savedProject: nil)
        let log = SessionLogRenderer.render(
            metadata: metadata, events: events, shotGroups: [], timeZone: TimeZone(identifier: "UTC")!, shotLink: { _ in nil })
        #expect(log.contains("): Your notes say 80.\n") || log.hasSuffix("): Your notes say 80."))
        let session = LoadedSession(metadata: metadata, events: events, shotGroups: [])
        let timeline = SessionBrowsing.timeline(for: session, shotsDirectory: URL(fileURLWithPath: "/tmp/none", isDirectory: true))
        #expect(timeline.last?.text == "Your notes say 80.")
    }

    // MARK: 10. Instructions

    @Test func theDigDeeperRuleKeepsTheAnswerShape() {
        let instructions = AnswerInstructions.questionInstructions(brainAccess: .passagesAndTools(mapPaths: []))
        #expect(instructions.contains("a short cursor part first, then [CHAT] and the fuller answer"))
    }

    // MARK: 11. A search announcement shows and speaks at the tool call

    @Test func theSearchAnnouncementShowsAndSpeaksAtTheToolCallBeforeAnyLaterText() {
        var run = AnswerStreamRun()
        run.raw("Let me check your notes for the demo port.")
        #expect(run.lines.isEmpty)
        run.toolCall()
        #expect(run.lines == [line("Let me check your notes for the demo port.")])
        #expect(run.spoken == ["Let me check your notes for the demo port."])
    }
}
