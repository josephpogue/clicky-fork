import Foundation

/// Cuts the visible answer text into sentences to speak as they complete, each returned once.
public struct SpokenSentenceSplitter: Equatable, Sendable {
    /// How many characters of the visible text have been handed out already
    private var spokenCharacterCount = 0

    public init() {}

    public mutating func newSentences(visibleTextSoFar: String, isFinal: Bool) -> [String] {
        let characters = Array(visibleTextSoFar)
        // Text that shrank, or was rewritten before the spoken part, only ever speaks its unspoken suffix.
        guard characters.count > spokenCharacterCount else { return [] }

        var sentences: [String] = []
        var sentenceStart = spokenCharacterCount
        var index = spokenCharacterCount
        while index < characters.count {
            let character = characters[index]
            if ".!?".contains(character), index + 1 < characters.count, characters[index + 1].isWhitespace,
               !Self.endsAbbreviation(characters, periodIndex: index) {
                Self.appendSentence(characters[sentenceStart...index], to: &sentences)
                sentenceStart = index + 1
                spokenCharacterCount = sentenceStart
            }
            index += 1
        }
        if isFinal {
            Self.appendSentence(characters[sentenceStart...], to: &sentences)
            spokenCharacterCount = characters.count
        }
        return sentences
    }

    /// A tool call began, so no text follows the visible text for a while: a trailing sentence that ends in `.`, `!`
    /// or `?` is complete even with no space after it yet. "Version 4.4" or "e.g." at the very end stays unspoken.
    public mutating func newSentencesAtToolCall(visibleTextSoFar: String) -> [String] {
        var sentences = newSentences(visibleTextSoFar: visibleTextSoFar, isFinal: false)
        let characters = Array(visibleTextSoFar)
        guard characters.count > spokenCharacterCount else { return sentences }
        var lastIndex = characters.count - 1
        while lastIndex >= spokenCharacterCount, characters[lastIndex].isWhitespace { lastIndex -= 1 }
        guard lastIndex >= spokenCharacterCount, ".!?".contains(characters[lastIndex]),
              !Self.endsAbbreviation(characters, periodIndex: lastIndex) else { return sentences }
        Self.appendSentence(characters[spokenCharacterCount...lastIndex], to: &sentences)
        spokenCharacterCount = characters.count
        return sentences
    }

    private static func appendSentence(_ slice: ArraySlice<Character>, to sentences: inout [String]) {
        let text = String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { sentences.append(text) }
    }

    /// "e.g." and "i.e." end in a period but not a sentence.
    private static func endsAbbreviation(_ characters: [Character], periodIndex: Int) -> Bool {
        guard characters[periodIndex] == "." else { return false }
        for abbreviation in ["e.g.", "i.e."] {
            let length = abbreviation.count
            guard periodIndex + 1 >= length else { continue }
            let tail = String(characters[(periodIndex + 1 - length)...periodIndex]).lowercased()
            if tail == abbreviation { return true }
        }
        return false
    }
}
