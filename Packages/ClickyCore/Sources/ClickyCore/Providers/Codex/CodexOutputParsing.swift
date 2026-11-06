import Foundation

/// What the JSON lines of one `codex exec --json` run said.
struct CodexTurnOutput: Equatable {
    var threadID: String?
    /// The text of the last `agent_message` item.
    var answerText: String?
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
}

/// Pure helpers for the text the `codex` tool prints and the text the app sends it.
enum CodexOutputParsing {
    /// The words the CLI prints when the plan's allowance is used up ("You've hit your usage limit ...").
    static let usageLimitPhrase = "hit your usage limit"

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
                    output.answerText = text
                } else if itemType == "error", let message = item["message"] as? String {
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

    /// True for a line that proves the stored login does not work, so waiting for the retries is pointless.
    static func lineShowsRejectedLogin(_ line: String) -> Bool {
        line.contains("401 Unauthorized")
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

    /// The prompt for a question: each image label in order, the context note, then the question.
    /// The images themselves travel in `-i` arguments in the same order.
    static func promptText(for turn: QuestionTurn) -> String {
        var sections: [String] = []
        if !turn.images.isEmpty {
            let labelLines = turn.images.enumerated().map { index, image in
                "Image \(index + 1): \(image.label)"
            }
            sections.append("Attached images, in order:\n" + labelLines.joined(separator: "\n"))
        }
        if !turn.contextNote.isEmpty {
            sections.append(turn.contextNote)
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
