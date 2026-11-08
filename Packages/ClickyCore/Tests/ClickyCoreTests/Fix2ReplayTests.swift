import Foundation
import Testing
@testable import ClickyCore

/// Fix wave 2, item 5: the testenv stand-in answers, fed delta by delta exactly as `testenv/claude-standin/claude`
/// streams them, through the pipeline the coordinator uses. After every delta the bubble holds only whole sentences,
/// grows within a part, and the voice reads each shown sentence once, in order.
@Suite("Fix wave 2: stand-in answer replay")
struct Fix2ReplayTests {
    /// The stand-in's `stream_text`: `words_per_delta` words per delta, a space before every delta but the first, and
    /// with `splitChatMarker` the marker arriving half written ("[CH", then "AT]").
    private func standInDeltas(_ text: String, wordsPerDelta: Int, splitChatMarker: Bool = false) -> [String] {
        let words = text.components(separatedBy: " ")
        var deltas: [String] = []
        var position = 0
        while position < words.count {
            let chunk = words[position..<min(position + wordsPerDelta, words.count)]
            let delta = (position > 0 ? " " : "") + chunk.joined(separator: " ")
            position += chunk.count
            if splitChatMarker, let markerRange = delta.range(of: "[CHAT]") {
                let cutIndex = delta.index(markerRange.lowerBound, offsetBy: 3)
                deltas.append(String(delta[..<cutIndex]))
                deltas.append(String(delta[cutIndex...]))
            } else {
                deltas.append(delta)
            }
        }
        return deltas
    }

    private let explainReply = "This menu bar holds the session controls. [CHAT] The first button starts the session. "
        + "The next ones open the chat, the session list and the settings. "
        + "Everything else on screen is not needed for now. [POINT:none]"
    private let longReply: String = (1...20)
        .map { "This is sentence number \($0) of a long answer with no chat marker." }
        .joined(separator: " ") + " [POINT:none]"

    /// What the bubble may show at any moment: the leading sentences of one expected part, and never anything else.
    /// Returns (part index, sentence count) or nil when the text is not a whole-sentence run of any expected part.
    private func position(of shownText: String, in expectedParts: [[String]]) -> (part: Int, count: Int)? {
        for partIndex in 0..<expectedParts.count {
            let sentences = expectedParts[partIndex]
            var count = 0
            var joined = ""
            while count < sentences.count {
                joined = count == 0 ? sentences[0] : joined + " " + sentences[count]
                count += 1
                if joined == shownText { return (partIndex, count) }
            }
        }
        return nil
    }

    /// The checks that hold after every delta, for any answer.
    private func checkAfterEveryStep(
        _ replay: AnswerReplay, expectedParts: [[String]], previous: (part: Int, count: Int)?
    ) -> (part: Int, count: Int)? {
        guard let line = replay.shownLine else { return previous }
        for forbidden in ["[", "]", "CHAT", "POINT", "[CH", "AT]"] {
            #expect(!line.text.contains(forbidden), "the bubble showed \(forbidden): \(line.text)")
        }
        if line.text.isEmpty { return previous }
        guard let now = position(of: line.text, in: expectedParts) else {
            Issue.record("the bubble showed text that is not whole sentences: \(line.text)")
            return previous
        }
        if let previous {
            #expect(now.part >= previous.part, "the bubble went back to an earlier part")
            if now.part == previous.part { #expect(now.count >= previous.count, "the bubble shrank within a part") }
        }
        // The voice reads only sentences the bubble showed, each once.
        var shownSoFar: [String] = []
        for partIndex in 0...now.part {
            let take = partIndex == now.part ? now.count : expectedParts[partIndex].count
            shownSoFar += expectedParts[partIndex].prefix(take)
        }
        #expect(Set(replay.spoken).isSubset(of: Set(shownSoFar)), "the voice read a sentence the bubble never showed")
        #expect(Set(replay.spoken).count == replay.spoken.count, "a sentence was read twice")
        return now
    }

    @Test func theExplainAnswerShowsOneWholeSentenceAndTheFooterWithoutEverShowingTheMarker() {
        var replay = AnswerReplay()
        let expected = [["This menu bar holds the session controls."]]
        var progress: (part: Int, count: Int)?
        var firstShownAfterDeltaIndex: Int?
        let deltas = standInDeltas(explainReply, wordsPerDelta: 3, splitChatMarker: true)
        var deltaIndex = 0
        replay.startBlock()
        for delta in deltas {
            replay.delta(delta)
            progress = checkAfterEveryStep(replay, expectedParts: expected, previous: progress)
            if replay.shownLine != nil, firstShownAfterDeltaIndex == nil { firstShownAfterDeltaIndex = deltaIndex }
            deltaIndex += 1
        }
        replay.final(explainReply)
        progress = checkAfterEveryStep(replay, expectedParts: expected, previous: progress)
        #expect(replay.shownLine == CursorLine(text: "This menu bar holds the session controls.", hasMoreInChat: true))
        #expect(replay.spoken == ["This menu bar holds the session controls."])
        // The sentence shows with the delta that ends it (three words each: the sentence ends in the third delta of
        // the first six words "This menu bar | holds the session | controls. [CH" ...), before the marker is whole.
        #expect(firstShownAfterDeltaIndex.map { deltas[$0].contains("[CH") || deltas[$0].contains("controls.") } == true)
    }

    @Test func theLongAnswerStartsAtSentenceOneGrowsOnlyAndEndsWithTheFooter() {
        var replay = AnswerReplay()
        let sentences = (1...20).map { "This is sentence number \($0) of a long answer with no chat marker." }
        var progress: (part: Int, count: Int)?
        replay.startBlock()
        for delta in standInDeltas(longReply, wordsPerDelta: 4) {
            replay.delta(delta)
            progress = checkAfterEveryStep(replay, expectedParts: [sentences], previous: progress)
        }
        replay.final(longReply)
        progress = checkAfterEveryStep(replay, expectedParts: [sentences], previous: progress)
        #expect(replay.shownLines.first?.text == sentences[0])
        let last = try! #require(replay.shownLine)
        #expect(last.hasMoreInChat)
        #expect(last.text.hasPrefix(sentences[0]))
        #expect(modelledBubbleFits(last.text))
        // One more sentence would not have fitted.
        let shownCount = try! #require(progress).count
        #expect(shownCount < 20)
        #expect(!modelledBubbleFits(last.text + " " + sentences[shownCount]))
        #expect(replay.spoken == Array(sentences.prefix(shownCount)))
        // The line grew one whole sentence at a time.
        var index = 1
        while index < replay.shownLines.count {
            #expect(replay.shownLines[index].text.hasPrefix(replay.shownLines[index - 1].text))
            index += 1
        }
    }

    @Test func thePortAnswerShowsTheAnnouncementThenReplacesItWithTheFinding() {
        var replay = AnswerReplay()
        let expected = [
            ["Let me check your notes for the demo port."],
            ["Your notes say the demo server listens on port 4417."],
        ]
        var progress: (part: Int, count: Int)?
        replay.startBlock()
        for delta in standInDeltas("Let me check your notes for the demo port.", wordsPerDelta: 3) {
            replay.delta(delta)
            progress = checkAfterEveryStep(replay, expectedParts: expected, previous: progress)
        }
        // The tool call: the announcement shows and is spoken at once. It says it is checking, so no checking line.
        replay.toolCall()
        progress = checkAfterEveryStep(replay, expectedParts: expected, previous: progress)
        #expect(replay.shownLine == CursorLine(text: "Let me check your notes for the demo port.", hasMoreInChat: false))
        #expect(!replay.showsCheckingLine)
        #expect(replay.spoken == ["Let me check your notes for the demo port."])

        let finalReply = "Your notes say the demo server listens on port 4417. [CHAT] The port is set in demo-server.md under Wiki/Projects. [POINT:none]"
        replay.startBlock()
        for delta in standInDeltas(finalReply, wordsPerDelta: 3) {
            replay.delta(delta)
            progress = checkAfterEveryStep(replay, expectedParts: expected, previous: progress)
        }
        replay.final("Let me check your notes for the demo port. " + finalReply)
        progress = checkAfterEveryStep(replay, expectedParts: expected, previous: progress)
        #expect(replay.shownLine == CursorLine(text: "Your notes say the demo server listens on port 4417.", hasMoreInChat: true))
        #expect(!replay.showsCheckingLine)
        #expect(replay.spoken == [
            "Let me check your notes for the demo port.", "Your notes say the demo server listens on port 4417.",
        ])
    }

    @Test func theDeployAnswerShowsTheCheckingLineAloneThenTheFinding() {
        // The stand-in's "deploy" row: no preamble, the tool call starts at once, then a one-sentence finding.
        var replay = AnswerReplay()
        replay.toolCall()
        #expect(replay.shownLine == CursorLine(text: "", hasMoreInChat: false))
        #expect(replay.showsCheckingLine)
        let finalReply = "Deploys go through the release script in your notes. [POINT:none]"
        replay.startBlock()
        for delta in standInDeltas(finalReply, wordsPerDelta: 3) { replay.delta(delta) }
        replay.final(finalReply)
        #expect(replay.shownLine == CursorLine(text: "Deploys go through the release script in your notes.", hasMoreInChat: false))
        #expect(!replay.showsCheckingLine)
        #expect(replay.spoken == ["Deploys go through the release script in your notes."])
    }

    @Test func theCorrectionAnswerReplacesTheEarlierPartAndNeverStacksThem() {
        var replay = AnswerReplay()
        replay.startBlock()
        for delta in standInDeltas("From the screen this looks like the Debug build.", wordsPerDelta: 3) { replay.delta(delta) }
        replay.toolCall()
        let finalReply = "Correction: your notes say test builds use Release. [POINT:none]"
        replay.startBlock()
        for delta in standInDeltas(finalReply, wordsPerDelta: 3) { replay.delta(delta) }
        replay.final(finalReply)
        #expect(replay.shownLine == CursorLine(text: "Correction: your notes say test builds use Release.", hasMoreInChat: false))
        #expect(!replay.showsCheckingLine)
    }
}
