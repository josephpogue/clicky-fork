import Foundation

/// One thing a line of the `claude` stream-json output means for the answer being read.
enum ClaudeStreamEvent: Equatable {
    /// The per-turn `system`/`init` line. `apiKeySource` is "none" on a subscription login.
    case initialized(apiKeySource: String?)
    /// A new text block began (the model writes text, then calls a tool, then writes more text in a new block).
    case textBlockStarted
    case textDelta(String)
    /// The model began a brain tool call; the arguments are not streamed in yet.
    case toolCallStarted(BrainToolName)
    /// The finished assistant message holds the tool call with its full input.
    case toolCallMade(toolUseID: String, call: BrainToolCall)
    case toolResult(toolUseID: String, text: String)
    /// The `error` field of an assistant line, for example `rate_limit`.
    case assistantError(String)
    /// The end of the answer. `resultText` is nil when the CLI printed `null` (an interrupted answer).
    case finished(subtype: String, isError: Bool, resultText: String?)
}

/// Turns one stdout line of `claude -p --output-format stream-json --include-partial-messages` into events.
/// Pure: no state, no process. Lines it does not need (status, thinking, control responses) give no events.
enum ClaudeStreamParser {
    static func events(fromLine line: String) -> [ClaudeStreamEvent] {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = message["type"] as? String else {
            return []
        }
        switch type {
        case "system":
            guard message["subtype"] as? String == "init" else { return [] }
            return [.initialized(apiKeySource: message["apiKeySource"] as? String)]
        case "stream_event":
            return streamEvents(from: message["event"] as? [String: Any])
        case "assistant":
            return assistantEvents(from: message)
        case "user":
            return userEvents(from: message)
        case "result":
            return [.finished(
                subtype: message["subtype"] as? String ?? "",
                isError: message["is_error"] as? Bool ?? false,
                resultText: message["result"] as? String
            )]
        default:
            return []
        }
    }

    private static func streamEvents(from event: [String: Any]?) -> [ClaudeStreamEvent] {
        guard let event, let eventType = event["type"] as? String else { return [] }
        switch eventType {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return [] }
            if blockType == "text" { return [.textBlockStarted] }
            if blockType == "tool_use", let tool = brainTool(named: block["name"] as? String) {
                return [.toolCallStarted(tool)]
            }
            return []
        case "content_block_delta":
            // Only text deltas count; thinking and tool input deltas are not part of the answer.
            guard let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        default:
            return []
        }
    }

    private static func assistantEvents(from message: [String: Any]) -> [ClaudeStreamEvent] {
        var events: [ClaudeStreamEvent] = []
        if let errorKind = message["error"] as? String { events.append(.assistantError(errorKind)) }
        let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let tool = brainTool(named: block["name"] as? String),
                  let toolUseID = block["id"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            let argumentKey = tool == .searchBrain ? "query" : "path"
            let call = BrainToolCall(
                tool: tool,
                argument: input[argumentKey] as? String ?? "",
                argumentsFingerprint: fingerprint(of: input)
            )
            events.append(.toolCallMade(toolUseID: toolUseID, call: call))
        }
        return events
    }

    /// Tool results arrive as a `user` line. The line the CLI writes for an interrupt holds plain text, not a
    /// `tool_result`, so it gives no event here.
    private static func userEvents(from message: [String: Any]) -> [ClaudeStreamEvent] {
        guard let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        var events: [ClaudeStreamEvent] = []
        for block in content {
            guard block["type"] as? String == "tool_result",
                  let toolUseID = block["tool_use_id"] as? String else { continue }
            events.append(.toolResult(toolUseID: toolUseID, text: text(ofToolResultContent: block["content"])))
        }
        return events
    }

    private static func text(ofToolResultContent content: Any?) -> String {
        if let plainText = content as? String { return plainText }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private static func brainTool(named name: String?) -> BrainToolName? {
        BrainToolName.allCases.first { $0.claudeToolName == name }
    }

    /// Compact JSON with sorted keys, so two calls compare equal only when every argument matches.
    static func fingerprint(of input: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds one answer from the events of its lines: the text so far, the brain tool calls, the notes they named,
/// and whether the model is stuck repeating one call. Pure, so the order rules are tested without a process.
struct ClaudeAnswerAccumulator {
    private(set) var text = ""
    private(set) var toolCalls: [BrainToolCall] = []
    private(set) var notesRead: [String] = []
    private(set) var toolResultCharacterCount = 0
    private(set) var hasReceivedTextDelta = false
    /// True once the same call was made three times in a row.
    private(set) var repeatGuardTripped = false

    /// How many identical calls in a row end the answer.
    static let repeatLimit = 3

    private var separatorPending = false
    private var callsByToolUseID: [String: BrainToolCall] = [:]
    private var previousCall: BrainToolCall?
    private var identicalCallsInARow = 0

    /// Applies one event and returns the progress to report for it.
    mutating func apply(_ event: ClaudeStreamEvent) -> [AnswerProgress] {
        switch event {
        case .textBlockStarted:
            // The separator is added with the block's first text, so an empty block never leaves a stray space.
            separatorPending = true
            return []
        case .textDelta(let piece):
            if separatorPending && !text.isEmpty && !text.hasSuffix("\n") {
                text += " "
            }
            separatorPending = false
            text += piece
            hasReceivedTextDelta = true
            return [.textSoFar(text)]
        case .toolCallStarted(let tool):
            return [.toolCallStarted(tool)]
        case .toolCallMade(let toolUseID, let call):
            // The CLI repeats the finished assistant message for a block; count each call once.
            guard callsByToolUseID[toolUseID] == nil else { return [] }
            callsByToolUseID[toolUseID] = call
            toolCalls.append(call)
            if call == previousCall {
                identicalCallsInARow += 1
            } else {
                previousCall = call
                identicalCallsInARow = 1
            }
            if identicalCallsInARow >= Self.repeatLimit { repeatGuardTripped = true }
            return [.toolCallMade(call)]
        case .toolResult(let toolUseID, let resultText):
            guard let call = callsByToolUseID[toolUseID] else { return [] }
            let paths = BrainToolText.paths(inToolResult: resultText)
            for path in paths where !notesRead.contains(path) {
                notesRead.append(path)
            }
            toolResultCharacterCount += resultText.count
            return [.toolCallFinished(call, paths: paths, resultCharacterCount: resultText.count)]
        case .initialized, .assistantError, .finished:
            return []
        }
    }
}
