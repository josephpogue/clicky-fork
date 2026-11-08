import Foundation

/// Cuts answer text into whole sentences, each returned once.
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

    /// The whole sentences of `text`. While the text can still grow, the last sentence counts only once whitespace
    /// follows its end mark; once the text is complete, the last sentence counts even with no end mark.
    public static func sentences(in text: String, isTextComplete: Bool) -> [String] {
        var splitter = SpokenSentenceSplitter()
        return splitter.newSentences(visibleTextSoFar: text, isFinal: isTextComplete)
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
