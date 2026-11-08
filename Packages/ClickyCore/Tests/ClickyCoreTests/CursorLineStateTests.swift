import Testing
@testable import ClickyCore

@Suite("Cursor line state")
struct CursorLineStateTests {
    private let fits: (String) -> Bool = { $0.count <= 60 }

    private func part(_ cursorText: String, complete: Bool, marker: Bool = false, chat: String = "") -> AnswerPart {
        AnswerPart(cursorText: cursorText, chatText: chat, hasChatMarker: marker, isCursorTextComplete: complete)
    }

    @Test func oneUnfinishedSentenceShowsNothing() {
        var state = CursorLineState()
        let update = state.update(parts: [part("Click Save at the top right", complete: false)], fits: fits)
        #expect(update.line == nil)
        #expect(update.newSentencesToSpeak == [])
    }

    @Test func aFinishedSentenceShowsAndSpeaksWhileTheNextOneIsStillBeingWritten() {
        var state = CursorLineState()
        let update = state.update(parts: [part("Click Save at the top right. Then", complete: false)], fits: fits)
        #expect(update.line == CursorLine(text: "Click Save at the top right.", hasMoreInChat: false))
        #expect(update.newSentencesToSpeak == ["Click Save at the top right."])
    }

    @Test func theNextUpdateSpeaksOnlyTheNewSentence() {
        var state = CursorLineState()
        _ = state.update(parts: [part("Click Save at the top right. Then", complete: false)], fits: fits)
        let update = state.update(parts: [part("Click Save at the top right. Then press Done.", complete: true)], fits: fits)
        #expect(update.line == CursorLine(text: "Click Save at the top right. Then press Done.", hasMoreInChat: false))
        #expect(update.newSentencesToSpeak == ["Then press Done."])
    }

    @Test func aMarkerShowsTheFooterAndSpeaksTheSentence() {
        var state = CursorLineState()
        let update = state.update(
            parts: [part("This menu bar holds the session controls.", complete: true, marker: true, chat: "Start, Stop and Save.")],
            fits: fits)
        #expect(update.line == CursorLine(text: "This menu bar holds the session controls.", hasMoreInChat: true))
        #expect(update.newSentencesToSpeak == ["This menu bar holds the session controls."])
    }

    @Test func sentencesThatDoNotFitAreLeftOutNotSpokenAndMarkedMoreInChat() {
        var state = CursorLineState()
        let update = state.update(
            parts: [part("First sentence is here. Second one is here. Third sentence will not fit.", complete: true)],
            fits: fits)
        #expect(update.line == CursorLine(text: "First sentence is here. Second one is here.", hasMoreInChat: true))
        #expect(update.newSentencesToSpeak == ["First sentence is here.", "Second one is here."])
    }

    @Test func aFirstSentenceThatDoesNotFitGivesTheFooterAlone() {
        var state = CursorLineState()
        let longSentence = String(repeating: "a", count: 69) + "."
        let update = state.update(parts: [part(longSentence, complete: true)], fits: fits)
        #expect(update.line == CursorLine(text: "", hasMoreInChat: true))
        #expect(update.newSentencesToSpeak == [])
    }

    @Test func aPartWithOnlyAMarkerIsTheFooterAlone() {
        var state = CursorLineState()
        let update = state.update(parts: [part("", complete: true, marker: true, chat: "Details.")], fits: fits)
        #expect(update.line == CursorLine(text: "", hasMoreInChat: true))
        #expect(update.newSentencesToSpeak == [])
    }

    @Test func aNewPartWithNoSentenceYetKeepsTheEarlierLineAndSpeaksNothing() {
        var state = CursorLineState()
        let first = part("Let me check your notes for the demo port.", complete: true)
        let firstUpdate = state.update(parts: [first], fits: fits)
        #expect(firstUpdate.newSentencesToSpeak == ["Let me check your notes for the demo port."])
        let update = state.update(parts: [first, part("Your notes say the demo", complete: false)], fits: fits)
        #expect(update.line == nil)
        #expect(update.newSentencesToSpeak == [])
    }

    @Test func aFirstUpdateWithAnUnfinishedNewestPartStillShowsTheEarlierPart() {
        var state = CursorLineState()
        let update = state.update(
            parts: [part("Let me check your notes for the demo port.", complete: true), part("Your notes say the demo", complete: false)],
            fits: fits)
        #expect(update.line == CursorLine(text: "Let me check your notes for the demo port.", hasMoreInChat: false))
    }

    @Test func aLaterPartReplacesTheEarlierLineAndItsSentencesAreNew() {
        var state = CursorLineState()
        let first = part("Let me check your notes for the demo port.", complete: true)
        _ = state.update(parts: [first], fits: fits)
        _ = state.update(parts: [first, part("Your notes say the demo", complete: false)], fits: fits)
        let update = state.update(
            parts: [first, part("Your notes say the demo server listens on 4417.", complete: true)], fits: fits)
        #expect(update.line == CursorLine(text: "Your notes say the demo server listens on 4417.", hasMoreInChat: false))
        #expect(update.newSentencesToSpeak == ["Your notes say the demo server listens on 4417."])
    }

    @Test func aCorrectionPartReplacesTheLine() {
        var state = CursorLineState()
        let update = state.update(
            parts: [
                part("From the screen this looks like the Debug build.", complete: true),
                part("Correction: your notes say test builds use Release.", complete: true),
            ], fits: fits)
        #expect(update.line == CursorLine(text: "Correction: your notes say test builds use Release.", hasMoreInChat: false))
    }

    @Test func eDotGDoesNotEndASentence() {
        var state = CursorLineState()
        let update = state.update(parts: [part("Use e.g. the Save button. Then wait", complete: false)], fits: fits)
        #expect(update.line == CursorLine(text: "Use e.g. the Save button.", hasMoreInChat: false))
        #expect(update.newSentencesToSpeak == ["Use e.g. the Save button."])
    }

    @Test func noChangeReturnsNoLine() {
        var state = CursorLineState()
        let parts = [part("Click Save at the top right.", complete: true)]
        #expect(state.update(parts: parts, fits: fits).line != nil)
        #expect(state.update(parts: parts, fits: fits).line == nil)
    }

    @Test func noticeKeepsOnlyTheSentencesThatFit() {
        let line = CursorLine.notice(
            text: "Clicky could not start. Turn on Accessibility in System Settings.", fits: { $0.count <= 30 })
        #expect(line == CursorLine(text: "Clicky could not start.", hasMoreInChat: true))
    }

    @Test func noticeThatFitsHasNoFooter() {
        let line = CursorLine.notice(text: "Clicky could not start.", fits: { $0.count <= 30 })
        #expect(line == CursorLine(text: "Clicky could not start.", hasMoreInChat: false))
    }

    @Test func noSentenceIsSpokenTwiceAcrossAStreamedSequence() {
        var state = CursorLineState()
        let fullText = "One is here. Two is here. Three is here. Four is here. Five is here. Six is here."
        let characters = Array(fullText)
        var spoken: [String] = []
        var length = 1
        while length <= characters.count {
            let text = String(characters[0..<length]).trimmingCharacters(in: .whitespaces)
            let update = state.update(parts: [part(text, complete: length == characters.count)], fits: fits)
            spoken += update.newSentencesToSpeak
            length += 1
        }
        #expect(spoken == ["One is here.", "Two is here.", "Three is here.", "Four is here."])
    }
}
