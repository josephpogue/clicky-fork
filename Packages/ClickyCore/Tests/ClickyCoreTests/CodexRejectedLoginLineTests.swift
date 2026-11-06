import Foundation
import Testing
@testable import ClickyCore

struct CodexRejectedLoginLineTests {
    @Test func errorLineWithA401IsARejectedLogin() {
        let line = #"{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer)"}"#
        #expect(CodexOutputParsing.lineShowsRejectedLogin(line))
    }

    @Test func failedTurnWithA401IsARejectedLogin() {
        let line = #"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}"#
        #expect(CodexOutputParsing.lineShowsRejectedLogin(line))
    }

    @Test func errorItemWithA401IsARejectedLogin() {
        let line = #"{"type":"item.completed","item":{"id":"item_1","type":"error","message":"401 Unauthorized"}}"#
        #expect(CodexOutputParsing.lineShowsRejectedLogin(line))
    }

    @Test func anAnswerQuotingA401IsNotARejectedLogin() {
        let line = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"The page says 401 Unauthorized."}}"#
        #expect(!CodexOutputParsing.lineShowsRejectedLogin(line))
    }

    @Test func errorsWithoutA401AndNonJsonLinesAreNotARejectedLogin() {
        #expect(!CodexOutputParsing.lineShowsRejectedLogin(#"{"type":"error","message":"You've hit your usage limit"}"#))
        #expect(!CodexOutputParsing.lineShowsRejectedLogin("plain text 401 Unauthorized"))
        #expect(!CodexOutputParsing.lineShowsRejectedLogin(#"{"type":"turn.started"}"#))
    }

    @Test func harmlessNoticesPrintedOnEveryTurnAreNotKeptAsErrors() {
        let lines = [
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Code Mode is unavailable because code-mode host is disabled. Code mode will fail closed."}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"error","message":"Model metadata for `x` not found. Defaulting to fallback metadata."}}"#,
            #"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#,
        ]

        let output = CodexOutputParsing.parseTurnOutput(lines: lines)

        #expect(output.errorMessages == ["You've hit your usage limit."])
    }
}
