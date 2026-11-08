import Foundation
import Testing
@testable import ClickyCore

@Suite("Answer parts")
struct AnswerPartsTests {
    @Test func aMarkerSplitsCursorTextFromChatText() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("This menu bar holds the session controls. [CHAT] The first button starts")
        #expect(tracker.parts == [AnswerPart(
            cursorText: "This menu bar holds the session controls.", chatText: "The first button starts",
            hasChatMarker: true, isCursorTextComplete: true)])
        #expect(tracker.chatText == "This menu bar holds the session controls.\n\nThe first button starts")
    }

    @Test func aToolCallStartsANewPart() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me check your notes for the demo port.")
        tracker.toolCallStarted()
        tracker.textReported("Let me check your notes for the demo port. Your notes say the demo server listens on port 4417.")
        #expect(tracker.parts == [
            AnswerPart(cursorText: "Let me check your notes for the demo port.", chatText: "",
                       hasChatMarker: false, isCursorTextComplete: true),
            AnswerPart(cursorText: "Your notes say the demo server listens on port 4417.", chatText: "",
                       hasChatMarker: false, isCursorTextComplete: false),
        ])
        tracker.finalReported("Let me check your notes for the demo port. Your notes say the demo server listens on port 4417.")
        #expect(tracker.parts.map(\.isCursorTextComplete) == [true, true])
        #expect(tracker.chatText == "Let me check your notes for the demo port.\n\nYour notes say the demo server listens on port 4417.")
    }

    @Test func aToolCallBeforeAnyTextMakesNoEmptyPart() {
        var tracker = AnswerPartsTracker()
        tracker.toolCallStarted()
        tracker.toolCallStarted()
        tracker.textReported("Deploys go through the release script in your notes.")
        #expect(tracker.parts.count == 1)
        #expect(tracker.parts[0].cursorText == "Deploys go through the release script in your notes.")
    }

    @Test func twoToolCallsInARowMakeNoEmptyPart() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Checking.")
        tracker.toolCallStarted()
        tracker.toolCallStarted()
        tracker.textReported("Checking. Found it.")
        #expect(tracker.parts.map(\.cursorText) == ["Checking.", "Found it."])
    }

    @Test func aCorrectionSentenceStartsANewPart() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("From the screen this looks like the Debug build. Correction: your notes say test builds use Release.")
        #expect(tracker.parts.count == 2)
        #expect(tracker.parts[0].cursorText == "From the screen this looks like the Debug build.")
        #expect(tracker.parts[0].isCursorTextComplete)
        #expect(tracker.parts[1].cursorText == "Correction: your notes say test builds use Release.")
    }

    @Test func aHalfWrittenCorrectionStaysInThePart() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("The port is 80. Correc")
        #expect(tracker.parts == [AnswerPart(
            cursorText: "The port is 80. Correc", chatText: "", hasChatMarker: false, isCursorTextComplete: false)])
    }

    @Test func aCorrectionAtTheStartIsOnePart() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Correction: it is 90.")
        #expect(tracker.parts.map(\.cursorText) == ["Correction: it is 90."])
    }

    @Test func aMarkerAtTheStartLeavesTheCursorTextEmpty() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("[CHAT] Everything here.")
        #expect(tracker.parts == [AnswerPart(
            cursorText: "", chatText: "Everything here.", hasChatMarker: true, isCursorTextComplete: true)])
    }

    @Test func extraMarkersBecomeParagraphBreaks() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("A. [CHAT] B. [CHAT] C.")
        #expect(tracker.parts.count == 1)
        #expect(tracker.parts[0].cursorText == "A.")
        #expect(tracker.parts[0].chatText == "B.\n\nC.")
        #expect(tracker.chatText == "A.\n\nB.\n\nC.")
    }

    @Test func eachPartKeepsItsOwnChatText() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Checking. [CHAT] Detail one.")
        tracker.toolCallStarted()
        tracker.textReported("Checking. [CHAT] Detail one. Found it. [CHAT] Detail two.")
        #expect(tracker.parts.map(\.cursorText) == ["Checking.", "Found it."])
        #expect(tracker.parts.map(\.chatText) == ["Detail one.", "Detail two."])
        #expect(tracker.chatText == "Checking.\n\nDetail one.\n\nFound it.\n\nDetail two.")
    }

    @Test func staticChatTextMatchesAFreshTracker() {
        #expect(AnswerPartsTracker.chatText(ofVisibleText: "A. [CHAT] B.") == "A.\n\nB.")
        #expect(AnswerPartsTracker.chatText(ofVisibleText: "") == "")
    }

    @Test func aShortAnswerIsOnePartWithNoMarker() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Click the Save button at the top right.")
        #expect(tracker.parts.count == 1)
        #expect(!tracker.parts[0].hasChatMarker)
        tracker.finalReported("Click the Save button at the top right.")
        #expect(tracker.parts[0].isCursorTextComplete)
        #expect(tracker.chatText == "Click the Save button at the top right.")
    }

    @Test func noTextMeansNoParts() {
        var tracker = AnswerPartsTracker()
        #expect(tracker.parts.isEmpty)
        tracker.toolCallStarted()
        #expect(tracker.parts.isEmpty)
        #expect(tracker.chatText == "")
    }

    @Test func aFinalWithNoStreamedTextSplitsByMarkersAndCorrections() {
        var tracker = AnswerPartsTracker()
        tracker.finalReported("One. [CHAT] Two. Correction: Three.")
        #expect(tracker.parts.map(\.cursorText) == ["One.", "Correction: Three."])
        #expect(tracker.parts.allSatisfy { $0.isCursorTextComplete })
    }

    @Test func aFinalKeepsToolBoundariesInsideTheCommonPrefix() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me check.")
        tracker.toolCallStarted()
        tracker.textReported("Let me check. Found it.")
        tracker.finalReported("Let me check. Found it, in fact.")
        #expect(tracker.parts.map(\.cursorText) == ["Let me check.", "Found it, in fact."])
    }

    @Test func aFinalDropsToolBoundariesThatTheFinalTextDoesNotShare() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me check the notes.")
        tracker.toolCallStarted()
        tracker.finalReported("Let me look at it. Done.")
        #expect(tracker.parts.map(\.cursorText) == ["Let me look at it. Done."])
    }

    @Test func textThatShrinksKeepsBoundariesClamped() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Hello there friend. Hmm")
        tracker.toolCallStarted()
        tracker.textReported("Hello")
        #expect(tracker.parts.map(\.cursorText) == ["Hello"])
        tracker.textReported("Hello there friend. Hmm done.")
        #expect(tracker.parts.map(\.cursorText) == ["Hello there friend. Hmm", "done."])
    }

    @Test func aLaterToolCallCompletesTheEarlierCursorText() {
        var tracker = AnswerPartsTracker()
        tracker.textReported("Let me check")
        #expect(tracker.parts[0].isCursorTextComplete == false)
        tracker.toolCallStarted()
        #expect(tracker.parts[0].isCursorTextComplete)
    }
}

@Suite("Chat marker in readers")
struct AnswerChatMarkerRemovingTests {
    @Test func removesTheMarkerAndJoinsThePieces() {
        #expect(AnswerChatMarker.removing(from: "A. [CHAT] B.", joinedBy: " ") == "A. B.")
        #expect(AnswerChatMarker.removing(from: "A. [CHAT] B.", joinedBy: "\n\n") == "A.\n\nB.")
        #expect(AnswerChatMarker.removing(from: "A. [CHAT] B. [CHAT] C.", joinedBy: " ") == "A. B. C.")
        #expect(AnswerChatMarker.removing(from: "[CHAT] B.", joinedBy: " ") == "B.")
        #expect(AnswerChatMarker.removing(from: "No marker here.", joinedBy: " ") == "No marker here.")
    }

    @Test func theLogLineDropsTheMarker() {
        let events = [SessionEvent(time: Date(timeIntervalSince1970: 0), kind: .answer(
            text: "A. [CHAT] B. [POINT:1,2:x:screen1]", provider: .claude, model: "sonnet",
            secondsToAnswer: 1, pointLabel: nil))]
        let rendered = SessionLogRenderer.render(
            metadata: SessionMetadata(id: "x", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, summary: nil, savedProject: nil),
            events: events, shotGroups: [], timeZone: TimeZone(identifier: "UTC")!, shotLink: { _ in nil })
        #expect(rendered.contains("s): A. B.\n") || rendered.hasSuffix("s): A. B."))
        #expect(!rendered.contains("[CHAT]"))
    }

    @Test func theSummaryInputDropsTheMarker() {
        let events = [SessionEvent(time: Date(timeIntervalSince1970: 0), kind: .answer(
            text: "A. [CHAT] B.", provider: .claude, model: "sonnet", secondsToAnswer: 1, pointLabel: nil))]
        let text = SessionSummaryInput.text(events: events, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasSuffix("Answer: A. B."))
    }

    @Test func theRecapDropsTheMarker() throws {
        let recap = try #require(RecapBuilder.recap(exchanges: [(question: "Q?", answer: "A. [CHAT] B.")]))
        #expect(recap.hasSuffix("A: A. B."))
    }

    @Test func sessionBrowsingShowsParagraphs() {
        let start = Date(timeIntervalSince1970: 0)
        let session = LoadedSession(
            metadata: SessionMetadata(id: "x", startedAt: start, endedAt: nil, summary: nil, savedProject: nil),
            events: [SessionEvent(time: start, kind: .answer(
                text: "A. [CHAT] B.", provider: .claude, model: "sonnet", secondsToAnswer: 1, pointLabel: nil))],
            shotGroups: [])
        let entries = SessionBrowsing.timeline(for: session, shotsDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(entries.first?.text == "A.\n\nB.")
    }
}

@Suite("Streaming answer text and the chat marker")
struct StreamingChatMarkerTests {
    @Test(arguments: ["[", "[C", "[CH", "[CHA", "[CHAT"])
    func aHalfWrittenMarkerIsHidden(suffix: String) {
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Hi there. " + suffix).visibleText == "Hi there.")
    }

    @Test func aCompleteMarkerStaysVisible() {
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Hi there. [CHAT] More").visibleText == "Hi there. [CHAT] More")
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Hi there. [CHAT]").visibleText == "Hi there. [CHAT]")
    }

    @Test func pointTagsAreStillHidden() {
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Hi [POINT:").visibleText == "Hi")
        #expect(StreamingAnswerText.visible(rawTextSoFar: "Hi [CHAT] x [POINT:1,2").visibleText == "Hi [CHAT] x")
    }
}

@Suite("Answer instructions with the chat marker")
struct AnswerInstructionsChatMarkerTests {
    private static let modes: [AnswerInstructions.BrainAccess] = [
        .off, .passagesOnly, .passagesAndTools(mapPaths: ["/a.md"]),
    ]

    @Test func everyModeTeachesTheMarker() {
        for mode in Self.modes {
            let text = AnswerInstructions.questionInstructions(brainAccess: mode)
            #expect(text.contains("[CHAT]"))
            #expect(text.contains("cursor part"))
            #expect(text.contains("[POINT:none]"))
            #expect(!text.contains("\u{2014}"))
            #expect(!text.lowercased().contains("spoken"))
        }
    }

    @Test func theMarkerSitsInTheRulesAndTheLongExample() {
        let text = AnswerInstructions.questionInstructions
        #expect(text.contains("Never mention the marker"))
        #expect(text.contains("Source Control menu at the top. [CHAT] "))
        // The long example ends with the point tag after the chat part.
        #expect(text.contains("[CHAT] Open the Source Control menu"))
    }

    @Test func toolRulesCoverParts() {
        let text = AnswerInstructions.questionInstructions(brainAccess: .passagesAndTools(mapPaths: []))
        #expect(text.contains("starts a new part"))
        #expect(text.contains("Correction:"))
        #expect(text.contains("Let me check your notes for the demo port."))
    }
}
