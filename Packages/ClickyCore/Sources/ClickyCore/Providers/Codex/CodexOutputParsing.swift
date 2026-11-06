import Foundation

/// What the JSON lines of one `codex exec --json` run said.
struct CodexTurnOutput: Equatable {
    var threadID: String?
    /// The text of every `agent_message` item, oldest first.
    var agentMessages: [String] = []
    /// Every agent message joined with a blank line between, so a searched answer that spoke before and after
    /// its findings reads as one answer. Nil when the run produced no agent message.
    var answerText: String? { agentMessages.isEmpty ? nil : CodexOutputParsing.joinedAgentMessages(agentMessages) }
    /// Every error message the run printed, oldest first (retry notices included).
    var errorMessages: [String] = []
    var turnFailedMessage: String?
    var turnCompleted = false
}

/// What `codex login status` said.
enum CodexLoginState: Equatable {
    case chatGPT
    case notLoggedIn
    /// Logged in some other way; `detail` is the part before any key text, e.g. "Logged in using an API key".
    case otherLogin(detail: String)
    case unknown
    /// Stop ended the status check before it answered.
    case cancelled
}

/// Pure helpers for the text the `codex` tool prints and the text the app sends it.
enum CodexOutputParsing {
    /// The words the CLI prints when the plan's allowance is used up ("You've hit your usage limit ...").
    static let usageLimitPhrase = "hit your usage limit"

    static func joinedAgentMessages(_ messages: [String]) -> String {
        messages.joined(separator: "\n\n")
    }

    /// The text of the `agent_message` item a `item.completed` line reports; nil for every other line.
    static func agentMessageText(inLine line: String) -> String? {
        // Cheap check first: this runs on the reader thread for every output line.
        guard line.contains("agent_message"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "item.completed",
              let item = object["item"] as? [String: Any],
              item["type"] as? String == "agent_message" else { return nil }
        return item["text"] as? String
    }

    /// The thread id a `thread.started` line reports; nil for every other line.
    static func threadID(inLine line: String) -> String? {
        guard line.contains("thread.started"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "thread.started" else { return nil }
        return object["thread_id"] as? String
    }

    static func parseTurnOutput(lines: [String]) -> CodexTurnOutput {
        var output = CodexTurnOutput()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "thread.started":
                if let threadID = object["thread_id"] as? String { output.threadID = threadID }
            case "item.completed":
                guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String else { continue }
                if itemType == "agent_message", let text = item["text"] as? String {
                    output.agentMessages.append(text)
                } else if itemType == "error", let message = item["message"] as? String, !isHarmlessNotice(message) {
                    output.errorMessages.append(message)
                }
            case "error":
                if let message = object["message"] as? String { output.errorMessages.append(message) }
            case "turn.failed":
                if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                    output.turnFailedMessage = message
                    output.errorMessages.append(message)
                }
            case "turn.completed":
                output.turnCompleted = true
            default:
                continue
            }
        }
        return output
    }

    /// Notices the CLI prints as error items on every turn that change nothing: with the tools off, code mode says it
    /// fails closed, and a model name the CLI has no metadata for gets a fallback. They must not become the message
    /// the chat shows when a turn fails for a real reason.
    private static func isHarmlessNotice(_ message: String) -> Bool {
        message.hasPrefix("Code Mode is unavailable") || message.hasPrefix("Model metadata for")
    }

    /// True for an error line that proves the stored login does not work, so waiting for the retries is pointless.
    /// Only the CLI's own error and failed-turn lines count. The model's answer (`agent_message`) can quote
    /// "401 Unauthorized" off the user's screen and must never be read as a rejected login.
    static func lineShowsRejectedLogin(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return false }

        var errorText: String?
        switch type {
        case "error":
            errorText = object["message"] as? String
        case "turn.failed":
            errorText = (object["error"] as? [String: Any])?["message"] as? String
        case "item.completed":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "error" else { return false }
            errorText = item["message"] as? String
        default:
            return false
        }
        return errorText?.contains("401 Unauthorized") ?? false
    }

    /// Turns the messages a failed run printed into the failure the chat should show.
    static func classifyFailure(messages: [String], standardErrorText: String) -> ProviderFailure {
        let allText = (messages + [standardErrorText]).joined(separator: "\n")
        let lowercasedText = allText.lowercased()

        if lowercasedText.contains(usageLimitPhrase) || lowercasedText.contains("usage limit") {
            let limitMessage = messages.last { $0.lowercased().contains("usage limit") } ?? "You've hit your ChatGPT usage limit."
            return .usageLimitReached(message: shortPlainMessage(from: limitMessage))
        }
        if lowercasedText.contains("401 unauthorized") || lowercasedText.contains("not logged in") {
            return .notSignedIn
        }
        let bestMessage = messages.last { !$0.isEmpty }
            ?? lastNonEmptyLine(of: standardErrorText)
            ?? "ChatGPT did not answer."
        return .failed(message: shortPlainMessage(from: bestMessage))
    }

    /// One line, no JSON wrapper, at most 200 characters.
    static func shortPlainMessage(from rawMessage: String) -> String {
        var message = rawMessage
        // Some errors arrive as a JSON string whose inner error holds the readable sentence.
        if let data = message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = object["error"] as? [String: Any],
           let innerMessage = inner["message"] as? String {
            message = innerMessage
        }
        let singleLine = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if singleLine.count > 200 {
            return String(singleLine.prefix(200)) + "..."
        }
        return singleLine
    }

    static func lastNonEmptyLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Reads the text of `codex login status` (the CLI prints it on stderr or stdout depending on version).
    static func parseLoginState(from text: String) -> CodexLoginState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Not logged in") { return .notLoggedIn }
        if trimmed.hasPrefix("Logged in using ChatGPT") { return .chatGPT }
        if trimmed.hasPrefix("Logged in using") {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            // Cut off any key fragment that follows " - ".
            let detail = firstLine.components(separatedBy: " - ").first ?? firstLine
            return .otherLogin(detail: detail.trimmingCharacters(in: .whitespaces))
        }
        return .unknown
    }

    // MARK: Text sent to the CLI

    /// The prompt for a question: the recap of earlier turns when the conversation has one that no thread holds yet
    /// (as Claude does, ahead of everything else), each image label in order, the context note, the passages found
    /// in the user's notes (when there are any), then the question.
    /// The images themselves travel in `-i` arguments in the same order.
    static func promptText(for turn: QuestionTurn, recap: String? = nil) -> String {
        var sections: [String] = []
        if let recap {
            sections.append(recap)
        }
        if !turn.images.isEmpty {
            let labelLines = turn.images.enumerated().map { index, image in
                "Image \(index + 1): \(image.label)"
            }
            sections.append("Attached images, in order:\n" + labelLines.joined(separator: "\n"))
        }
        if !turn.contextNote.isEmpty {
            sections.append(turn.contextNote)
        }
        if !turn.brainNote.isEmpty {
            sections.append(turn.brainNote)
        }
        sections.append("Question: \(turn.questionText)")
        return sections.joined(separator: "\n\n")
    }

    /// Escapes text as a TOML basic string, which is how `-c key=value` reads a value.
    static func tomlBasicString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// A prompt must not start with "-", or the CLI would read it as an option.
    static func safePromptArgument(_ prompt: String) -> String {
        prompt.hasPrefix("-") ? "\n" + prompt : prompt
    }
}
