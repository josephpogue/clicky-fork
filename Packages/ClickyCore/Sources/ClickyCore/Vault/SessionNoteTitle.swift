import Foundation

/// The title and file slug of a saved session.
public enum SessionNoteTitle {
    static let maximumTitleLength = 60
    static let maximumSlugLength = 50

    public static func make(
        summary: String?, firstQuestion: String?, startedAt: Date, timeZone: TimeZone
    ) -> (title: String, slug: String) {
        let title: String
        if let sentence = firstSentence(of: summary) {
            title = cut(sentence)
        } else if let question = collapse(firstQuestion), !question.isEmpty {
            title = cut(question)
        } else {
            title = "Session \(clockText(startedAt, timeZone))"
        }
        let slug = slugify(title)
        return (title, slug.isEmpty ? "session" : slug)
    }

    private static func collapse(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func firstSentence(of summary: String?) -> String? {
        guard let text = collapse(summary), !text.isEmpty else { return nil }
        var sentence = text
        if let end = text.firstIndex(where: { ".!?".contains($0) }) {
            let after = text.index(after: end)
            if after == text.endIndex || text[after] == " " { sentence = String(text[..<end]) }
        }
        let trimmed = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Cuts at a word boundary so the result is at most 60 characters.
    private static func cut(_ text: String) -> String {
        guard text.count > maximumTitleLength else { return text }
        let head = String(text.prefix(maximumTitleLength))
        let nextIsSpace = text[text.index(text.startIndex, offsetBy: maximumTitleLength)] == " "
        var result = head
        if !nextIsSpace, let lastSpace = head.lastIndex(of: " ") {
            result = String(head[..<lastSpace])
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
    }

    private static func clockText(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Lowercase a-z and 0-9 joined by single hyphens, at most 50 characters.
    static func slugify(_ text: String) -> String {
        var parts: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        var slug = parts.joined(separator: "-")
        if slug.count > maximumSlugLength {
            slug = String(slug.prefix(maximumSlugLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }
}
