import Foundation

/// Turns a spoken question into an FTS5 query: the meaningful words, each quoted, joined with OR.
enum BrainSearchQuery {
    static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "what", "which", "where", "when", "how", "why", "who", "do", "does", "did",
        "i", "my", "me", "you", "your", "it", "its", "of", "to", "in", "on", "for", "with", "about", "and", "or", "that",
        "this", "can", "should", "would", "could", "there", "be", "any", "from", "at", "by", "we", "our",
    ]

    /// The words that carry meaning, lowercased, in order, without repeats.
    static func meaningfulWords(in text: String) -> [String] {
        var words: [String] = []
        var seenWords = Set<String>()
        var currentWord = ""
        func finishWord() {
            defer { currentWord = "" }
            guard currentWord.count >= 2, !stopWords.contains(currentWord), seenWords.insert(currentWord).inserted else { return }
            words.append(currentWord)
        }
        // Splitting on every non-letter, non-digit also removes FTS syntax characters (quotes, `*`, `:`, `^`).
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                currentWord.append(character)
            } else {
                finishWord()
            }
        }
        finishWord()
        return words
    }

    /// nil when no words are left (the caller returns nothing instead of scanning the whole table).
    static func matchExpression(for question: String) -> String? {
        let words = meaningfulWords(in: question)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }
}
