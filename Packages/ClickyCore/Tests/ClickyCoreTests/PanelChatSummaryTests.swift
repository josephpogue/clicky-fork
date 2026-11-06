import Foundation
import Testing
@testable import ClickyCore

/// The menu-bar panel's Open chat row shows an answer count and the start of the last answer.
struct PanelChatSummaryTests {
    @Test func noAnswersGivesNoCountAndNoLastLine() {
        #expect(PanelChatSummary.countText(answerCount: 0) == nil)
        #expect(PanelChatSummary.lastLine(lastAnswerText: nil) == nil)
    }

    @Test func countReadsSingularAndPlural() {
        #expect(PanelChatSummary.countText(answerCount: 1) == "1 answer")
        #expect(PanelChatSummary.countText(answerCount: 3) == "3 answers")
    }

    @Test func lastLineCollapsesNewlinesAndWhitespaceRuns() {
        let text = "Click Code, copy the HTTPS link,\n then run git clone with it in Terminal."
        #expect(PanelChatSummary.lastLine(lastAnswerText: text)
            == "Last: Click Code, copy the HTTPS link, then run git clone with it in Terminal.")
        #expect(PanelChatSummary.lastLine(lastAnswerText: "  a \t\n\n b  ") == "Last: a b")
    }

    @Test func blankLastAnswerGivesNoLastLine() {
        #expect(PanelChatSummary.lastLine(lastAnswerText: " \n ") == nil)
    }

    @Test func accessibilityValueHoldsCountAndFullText() {
        #expect(PanelChatSummary.accessibilityValue(answerCount: 0, lastAnswerText: nil) == "")
        #expect(PanelChatSummary.accessibilityValue(answerCount: 3, lastAnswerText: "Do a\nthing")
            == "3 answers. Last: Do a thing")
    }
}
