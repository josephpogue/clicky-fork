import Foundation
import Testing
@testable import ClickyCore

@Suite("Context note builder")
struct QuestionsContextNoteTests {
    private func event(_ hour: Int, _ minute: Int, _ kind: SessionEventKind) -> SessionEvent {
        SessionEvent(time: QuestionsFixtures.time(hour, minute), kind: kind)
    }

    private func note(_ events: [SessionEvent]) -> String {
        ContextNoteBuilder.note(events: events, timeZone: QuestionsFixtures.utc)
    }

    @Test func rendersFocusAndUtteranceLines() {
        let text = note([
            event(14, 3, .focusChanged(appName: "Terminal", windowTitle: "zsh")),
            event(14, 4, .utterance(text: "  ok let me try that  ")),
        ])
        #expect(text == "Since the last question:\n- 14:03 switched to Terminal (zsh)\n- 14:04 said: \"ok let me try that\"")
    }

    @Test func omitsParenthesesWithoutWindowTitle() {
        #expect(note([event(9, 5, .focusChanged(appName: "Finder", windowTitle: nil))])
            == "Since the last question:\n- 09:05 switched to Finder")
        #expect(note([event(9, 5, .focusChanged(appName: "Finder", windowTitle: ""))])
            == "Since the last question:\n- 09:05 switched to Finder")
    }

    @Test func leavesOutOtherKindsAndIsEmptyWithNoLines() {
        #expect(note([]) == "")
        #expect(note([event(10, 0, .questionStarted), event(10, 1, .screenshot(shotGroupID: 1))]) == "")
    }

    @Test func cutsLongUtterancesAt300Characters() {
        let long = String(repeating: "a", count: 350)
        let text = note([event(10, 0, .utterance(text: long))])
        let expectedSaid = String(repeating: "a", count: 300) + "..."
        #expect(text == "Since the last question:\n- 10:00 said: \"\(expectedSaid)\"")
    }

    @Test func keepsLastTwentyLinesWithLeftOutCount() {
        // 27 events: 27 - 20 = 7 left out
        let events = (0..<27).map { index in
            event(10, index, .utterance(text: "line \(index)"))
        }
        let lines = note(events).components(separatedBy: "\n")
        #expect(lines.count == 22) // header, left-out line, 20 events
        #expect(lines[1] == "- (7 earlier events left out)")
        #expect(lines[2] == "- 10:07 said: \"line 7\"")
        #expect(lines.last == "- 10:26 said: \"line 26\"")
    }
}
