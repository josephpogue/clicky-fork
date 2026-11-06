import Foundation
import Testing
@testable import ClickyCore

/// The lines below are copied from a real `claude 2.1.318 --include-partial-messages` run with the brain tools
/// (usage and ids trimmed), so the parser is tested on the shapes the CLI really prints.
struct ClaudeStreamParserTests {
    private let textBlockStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s"}"#
    private let firstDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Searching the"}},"session_id":"s"}"#
    private let toolStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01Ra","name":"mcp__brain__search_brain","input":{},"caller":{"type":"direct"}}},"session_id":"s"}"#
    private let inputDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query"}},"session_id":"s"}"#
    private let toolAssistant = #"{"type":"assistant","message":{"model":"claude-haiku-5-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_01Ra","name":"mcp__brain__search_brain","input":{"query":"design-vault port"},"caller":{"type":"direct"}}]},"session_id":"s"}"#
    private let toolResultLine = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01Ra","type":"tool_result","content":[{"type":"text","text":"File: /notes/design-vault.md lines 1-4\nport is 4417"}]}]},"session_id":"s"}"#
    private let interruptedUserLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"session_id":"s"}"#
    private let successResult = #"{"type":"result","subtype":"success","is_error":false,"result":"design-vault runs on port 4417.","stop_reason":"end_turn","session_id":"s"}"#
    private let interruptedResult = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":null,"stop_reason":null,"session_id":"s"}"#

    @Test func textBlockAndDeltaBecomeTextEvents() {
        #expect(ClaudeStreamParser.events(fromLine: textBlockStart) == [.textBlockStarted])
        #expect(ClaudeStreamParser.events(fromLine: firstDelta) == [.textDelta("Searching the")])
    }

    @Test func thinkingAndToolInputDeltasAreNotText() {
        let thinkingDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#
        let thinkingStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#
        #expect(ClaudeStreamParser.events(fromLine: thinkingDelta).isEmpty)
        #expect(ClaudeStreamParser.events(fromLine: thinkingStart).isEmpty)
        #expect(ClaudeStreamParser.events(fromLine: inputDelta).isEmpty)
    }

    @Test func aBrainToolBlockStartsAToolCallButAnotherToolDoesNot() {
        #expect(ClaudeStreamParser.events(fromLine: toolStart) == [.toolCallStarted(.searchBrain)])
        let otherTool = toolStart.replacingOccurrences(of: "mcp__brain__search_brain", with: "Bash")
        #expect(ClaudeStreamParser.events(fromLine: otherTool).isEmpty)
    }

    @Test func assistantToolUseCarriesTheArgumentAndASortedKeysFingerprint() {
        let events = ClaudeStreamParser.events(fromLine: toolAssistant)
        let expectedCall = BrainToolCall(
            tool: .searchBrain,
            argument: "design-vault port",
            argumentsFingerprint: #"{"query":"design-vault port"}"#
        )
        #expect(events == [.toolCallMade(toolUseID: "toolu_01Ra", call: expectedCall)])
    }

    @Test func readToolUsesThePathAndFingerprintSortsEveryKey() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"mcp__brain__read_brain_file","input":{"path":"/a/b.md","start_line":3,"line_count":40}}]}}"#
        let events = ClaudeStreamParser.events(fromLine: line)
        guard case .toolCallMade(_, let call) = events.first else {
            Issue.record("no tool call")
            return
        }
        #expect(call.tool == .readBrainFile)
        #expect(call.argument == "/a/b.md")
        #expect(call.argumentsFingerprint == #"{"line_count":40,"path":"/a/b.md","start_line":3}"#)
    }

    @Test func toolResultLineGivesItsTextByToolUseID() {
        #expect(ClaudeStreamParser.events(fromLine: toolResultLine) == [
            .toolResult(toolUseID: "toolu_01Ra", text: "File: /notes/design-vault.md lines 1-4\nport is 4417"),
        ])
    }

    @Test func theInterruptNoticeUserLineIsNotAToolResult() {
        #expect(ClaudeStreamParser.events(fromLine: interruptedUserLine).isEmpty)
    }

    @Test func resultLinesCarryTheirKind() {
        #expect(ClaudeStreamParser.events(fromLine: successResult) == [
            .finished(subtype: "success", isError: false, resultText: "design-vault runs on port 4417."),
        ])
        #expect(ClaudeStreamParser.events(fromLine: interruptedResult) == [
            .finished(subtype: "error_during_execution", isError: true, resultText: nil),
        ])
    }

    @Test func initCarriesTheKeySourceAndUnknownLinesGiveNothing() {
        let initLine = #"{"type":"system","subtype":"init","apiKeySource":"none","tools":["mcp__brain__search_brain"]}"#
        #expect(ClaudeStreamParser.events(fromLine: initLine) == [.initialized(apiKeySource: "none")])
        #expect(ClaudeStreamParser.events(fromLine: #"{"type":"system","subtype":"status","status":"requesting"}"#).isEmpty)
        #expect(ClaudeStreamParser.events(fromLine: "not json").isEmpty)
    }

    // MARK: Accumulator

    private func run(_ lines: [String]) -> (accumulator: ClaudeAnswerAccumulator, reports: [AnswerProgress]) {
        var accumulator = ClaudeAnswerAccumulator()
        var reports: [AnswerProgress] = []
        for line in lines {
            for event in ClaudeStreamParser.events(fromLine: line) {
                reports += accumulator.apply(event)
            }
        }
        return (accumulator, reports)
    }

    @Test func aPreambleSearchFindingStreamReportsInOrder() {
        let secondBlockStart = textBlockStart
        let findingDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"design-vault runs on port 4417."}}}"#
        let result = run([textBlockStart, firstDelta, toolStart, inputDelta, toolAssistant, toolResultLine, secondBlockStart, findingDelta, successResult])
        let call = BrainToolCall(tool: .searchBrain, argument: "design-vault port", argumentsFingerprint: #"{"query":"design-vault port"}"#)
        #expect(result.reports == [
            .textSoFar("Searching the"),
            .toolCallStarted(.searchBrain),
            .toolCallMade(call),
            .toolCallFinished(call, paths: ["/notes/design-vault.md"], resultCharacterCount: 51),
            .textSoFar("Searching the design-vault runs on port 4417."),
        ])
        #expect(result.accumulator.toolCalls == [call])
        #expect(result.accumulator.notesRead == ["/notes/design-vault.md"])
        #expect(result.accumulator.toolResultCharacterCount == 51)
    }

    @Test func separateTextBlocksJoinWithOneSpaceUnlessTheEarlierOneEndsInANewline() {
        func delta(_ text: String) -> String {
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
        }
        let withSpace = run([textBlockStart, delta("One."), textBlockStart, delta("Two.")])
        #expect(withSpace.accumulator.text == "One. Two.")
        let withNewline = run([textBlockStart, delta("One.\\n"), textBlockStart, delta("Two.")])
        #expect(withNewline.accumulator.text == "One.\nTwo.")
        // A text block that never gets text leaves no stray space.
        let emptyBlock = run([textBlockStart, delta("One."), textBlockStart, textBlockStart, delta("Two.")])
        #expect(emptyBlock.accumulator.text == "One. Two.")
    }

    @Test func theSameFinishedToolCallSeenTwiceCountsOnce() {
        let result = run([toolAssistant, toolAssistant])
        #expect(result.accumulator.toolCalls.count == 1)
    }

    @Test func theThirdIdenticalCallInARowTripsTheRepeatGuardButADifferentOneDoesNot() {
        func call(_ id: String, _ query: String) -> String {
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"mcp__brain__search_brain","input":{"query":"\#(query)"}}]}}"#
        }
        let two = run([call("a", "x"), call("b", "x")])
        #expect(two.accumulator.repeatGuardTripped == false)
        let three = run([call("a", "x"), call("b", "x"), call("c", "x")])
        #expect(three.accumulator.repeatGuardTripped)
        let broken = run([call("a", "x"), call("b", "x"), call("c", "y"), call("d", "x")])
        #expect(broken.accumulator.repeatGuardTripped == false)
    }

    @Test func aResultForAnUnknownToolUseIsIgnored() {
        let result = run([toolResultLine])
        #expect(result.reports.isEmpty)
        #expect(result.accumulator.notesRead.isEmpty)
    }
}
