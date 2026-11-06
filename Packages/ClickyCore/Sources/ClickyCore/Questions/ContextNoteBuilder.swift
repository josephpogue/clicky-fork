import Foundation

/// Renders what happened since the last question as a short note for the AI.
public enum ContextNoteBuilder {
    private static let maximumLines = 20
    private static let maximumUtteranceCharacters = 300

    public static func note(events: [SessionEvent], timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        var lines: [String] = []
        for event in events {
            let clock = formatter.string(from: event.time)
            switch event.kind {
            case .focusChanged(let appName, let windowTitle):
                if let windowTitle, !windowTitle.isEmpty {
                    lines.append("- \(clock) switched to \(appName) (\(windowTitle))")
                } else {
                    lines.append("- \(clock) switched to \(appName)")
                }
            case .utterance(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let shown = trimmed.count > maximumUtteranceCharacters
                    ? String(trimmed.prefix(maximumUtteranceCharacters)) + "..."
                    : trimmed
                lines.append("- \(clock) said: \"\(shown)\"")
            default:
                continue
            }
        }

        guard !lines.isEmpty else { return "" }
        if lines.count > maximumLines {
            let leftOut = lines.count - maximumLines
            let noun = leftOut == 1 ? "event" : "events"
            lines = ["- (\(leftOut) earlier \(noun) left out)"] + lines.suffix(maximumLines)
        }
        return "Since the last question:\n" + lines.joined(separator: "\n")
    }
}
