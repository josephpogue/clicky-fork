import Foundation

/// The text-only input for the one optional summary request at Stop. No images go with it.
public enum SessionSummaryInput {
    static let maximumCharacterCount = 6000

    /// Questions, answers (without POINT tags), spoken lines and app switches, each with its time.
    /// When the session is longer than the limit, the newest lines are kept.
    public static func text(events: [SessionEvent], timeZone: TimeZone) -> String {
        let clockFormatter = SessionLogText.timeFormatter(pattern: "HH:mm:ss", timeZone: timeZone)

        var lines: [String] = []
        for event in events {
            let clock = clockFormatter.string(from: event.time)
            switch event.kind {
            case .focusChanged(let appName, let windowTitle):
                var target = appName
                if let windowTitle, !windowTitle.isEmpty { target += ", \"\(SessionLogText.singleLine(windowTitle))\"" }
                lines.append("\(clock) Switched to \(target).")
            case .utterance(let spokenText):
                lines.append("\(clock) Said: \"\(SessionLogText.singleLine(spokenText))\"")
            case .question(let questionText, _, _):
                lines.append("\(clock) Question: \"\(SessionLogText.singleLine(questionText))\"")
            case .answer(let answerText, _, _, _, _):
                let plainAnswer = SessionLogText.singleLine(
                    AnswerChatMarker.removing(from: SessionLogText.removingPointTags(from: answerText), joinedBy: " "))
                lines.append("\(clock) Answer: \(plainAnswer)")
            default:
                break
            }
        }

        // Drop the oldest lines until what is left fits.
        var characterCount = lines.reduce(0) { $0 + $1.count + 1 } - 1
        while characterCount > maximumCharacterCount, lines.count > 1 {
            characterCount -= lines.removeFirst().count + 1
        }
        let joined = lines.joined(separator: "\n")
        return joined.count > maximumCharacterCount ? String(joined.suffix(maximumCharacterCount)) : joined
    }

    /// Sent with the text above as the summary request.
    public static let instructions = """
        You will read the log of a screen-sharing help session: what the user said, which apps and windows \
        they were in, the questions they asked and the answers they got. Write two or three plain sentences \
        saying what the user worked on and what they asked. Use plain words, past tense, no bullet points, \
        no headings and no quotation of the log. Reply with the sentences only.
        """
}
