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
            if SentenceRule.endsSentence(at: index, in: characters, isTextComplete: isFinal) {
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
}
