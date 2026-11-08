import Foundation

/// The one rule for where a sentence ends, shared by the speech splitter and the answer parts, so the bubble, the
/// voice and the part boundaries always agree.
public enum SentenceRule {
    /// Words that end in a period without ending a sentence.
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "st.", "vs."]

    /// True when the character at `index` ends a sentence: ".", "!" or "?" followed by whitespace, and for a period
    /// not the end of an abbreviation ("e.g.", "i.e.", "U.S.", "Dr.", "Mr.", "Mrs.", "Ms.", "St.", "vs."), a single
    /// capital initial ("J. Smith") or a list numeral ("1." at the start of the text, after a line break or after
    /// a sentence end). "etc." ends a sentence only when the next word starts with a capital letter.
    public static func endsSentence(at index: Int, in characters: [Character]) -> Bool {
        guard index >= 0, index < characters.count, ".!?".contains(characters[index]),
              index + 1 < characters.count, characters[index + 1].isWhitespace else { return false }
        guard characters[index] == "." else { return true }

        var tokenStart = index
        while tokenStart > 0, !characters[tokenStart - 1].isWhitespace { tokenStart -= 1 }
        // An opening quote or bracket is not part of the word.
        while tokenStart < index, "([\"'\u{201C}\u{2018}".contains(characters[tokenStart]) { tokenStart += 1 }
        let token = Array(characters[tokenStart...index])
        let lowercasedToken = String(token).lowercased()

        if abbreviations.contains(lowercasedToken) { return false }
        if isDottedLetters(token) { return false }
        if token.count == 2, token[0].isLetter, token[0].isUppercase { return false }
        if lowercasedToken == "etc." { return nextWordStartsWithCapital(after: index, in: characters) }
        if isListNumeral(token, startingAt: tokenStart, in: characters) { return false }
        return true
    }

    /// "U.S.", "U.K.", "e.g.": two or more single letters each followed by a period.
    private static func isDottedLetters(_ token: [Character]) -> Bool {
        guard token.count >= 4, token.count % 2 == 0 else { return false }
        var position = 0
        while position < token.count {
            if !token[position].isLetter || token[position + 1] != "." { return false }
            position += 2
        }
        return true
    }

    private static func isListNumeral(_ token: [Character], startingAt tokenStart: Int, in characters: [Character]) -> Bool {
        guard token.count >= 2 else { return false }
        var position = 0
        while position < token.count - 1 {
            if !token[position].isNumber { return false }
            position += 1
        }
        // What comes before the numeral: the start of the text, a line break, or the end of an earlier sentence.
        var before = tokenStart - 1
        while before >= 0, characters[before] == " " || characters[before] == "\t" { before -= 1 }
        if before < 0 { return true }
        return characters[before].isNewline || ".!?".contains(characters[before])
    }

    private static func nextWordStartsWithCapital(after index: Int, in characters: [Character]) -> Bool {
        var next = index + 1
        while next < characters.count, characters[next].isWhitespace { next += 1 }
        guard next < characters.count else { return false }
        return characters[next].isUppercase
    }
}
