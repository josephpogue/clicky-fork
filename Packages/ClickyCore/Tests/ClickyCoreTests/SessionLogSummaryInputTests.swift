import Testing
@testable import ClickyCore

struct SessionLogSummaryInputTests {
    typealias Support = SessionLogTestSupport

    private func event(_ time: String, _ kind: SessionEventKind) -> SessionEvent {
        SessionEvent(time: Support.date("2026-11-05T\(time)-05:00"), kind: kind)
    }

    @Test func textHoldsQuestionsAnswersSpeechAndAppSwitchesWithTimes() {
        let events = [
            event("14:02:11", .focusChanged(appName: "Safari", windowTitle: "Invoice 48213")),
            event("14:02:30", .utterance(text: "okay let me look at the total")),
            event("14:03:01", .question(text: "where do I pay this", shotGroupID: 4, earlierShotGroupIDs: [])),
            event("14:03:04", .answer(
                text: "Click the blue Pay now button. [POINT:1180,40:pay button]",
                provider: .claude, model: "sonnet", secondsToAnswer: 2.7, pointLabel: "pay button"
            )),
        ]

        let text = SessionSummaryInput.text(events: events, timeZone: Support.newYork)

        #expect(text == """
        14:02:11 Switched to Safari, "Invoice 48213".
        14:02:30 Said: "okay let me look at the total"
        14:03:01 Question: "where do I pay this"
        14:03:04 Answer: Click the blue Pay now button.
        """)
    }

    @Test func longSessionsKeepTheNewestLinesWithinAboutSixThousandCharacters() {
        var events: [SessionEvent] = []
        for number in 0..<400 {
            events.append(event("14:00:00", .utterance(text: "spoken line number \(number) with some padding words")))
        }

        let text = SessionSummaryInput.text(events: events, timeZone: Support.newYork)

        #expect(text.count <= 6000)
        #expect(text.count > 5000)
        #expect(text.contains("spoken line number 399 "))
        #expect(!text.contains("spoken line number 0 "))
    }

    @Test func instructionsAskForTwoOrThreePlainSentences() {
        #expect(SessionSummaryInput.instructions.contains("two or three"))
        #expect(!SessionSummaryInput.instructions.contains("\u{2014}"))
    }
}
