import Foundation

/// Small text helpers shared by the log renderer and the summary input.
enum SessionLogText {
    /// Removes every `[POINT:...]` tag, so the log and the summary read as plain sentences.
    static func removingPointTags(from text: String) -> String {
        let withoutTags = text.replacingOccurrences(
            of: #"\[POINT:[^\]]*\]"#, with: "", options: .regularExpression
        )
        let collapsedSpaces = withoutTags.replacingOccurrences(
            of: #" {2,}"#, with: " ", options: .regularExpression
        )
        return collapsedSpaces.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of text: newlines become spaces, so a timeline entry never breaks the markdown list.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func providerDisplayName(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    static func timeFormatter(pattern: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
