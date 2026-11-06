import Foundation

/// Decides when the app adds its own "Checking your notes" line while the AI searches.
/// It shows at most once per run of tool calls with no new answer text between them, and not when the answer
/// text written since the last tool call already says the AI is checking.
public struct CheckingNotesRule: Equatable, Sendable {
    public static let lineText = "Checking your notes"

    private static let checkingWords: Set<String> = [
        "check", "checking", "look", "looking", "search", "searching", "find", "finding", "dig", "digging",
    ]

    /// How much visible text had been written when the last tool call started (or finished the run)
    private var characterCountAtLastToolCall = 0
    private var latestVisibleText = ""
    private var lineShownSinceLastText = false

    public init() {}

    public mutating func textChanged(visibleTextSoFar: String) {
        if visibleTextSoFar.count > characterCountAtLastToolCall, visibleTextSoFar != latestVisibleText {
            // New answer text: a later tool call may show the line again.
            lineShownSinceLastText = false
        }
        latestVisibleText = visibleTextSoFar
    }

    /// True when the app should show and say its own line now.
    public mutating func toolCallStarted(visibleTextSoFar: String) -> Bool {
        textChanged(visibleTextSoFar: visibleTextSoFar)
        let textSinceLastToolCall = String(visibleTextSoFar.dropFirst(min(characterCountAtLastToolCall, visibleTextSoFar.count)))
        characterCountAtLastToolCall = visibleTextSoFar.count

        if lineShownSinceLastText { return false }
        let trimmed = textSinceLastToolCall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, Self.lastSentence(of: trimmed).saysItIsChecking { return false }
        lineShownSinceLastText = true
        return true
    }

    private static func lastSentence(of text: String) -> String {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        return sentences.last ?? text
    }
}

private extension String {
    /// Whether any whole word is one of the checking words.
    var saysItIsChecking: Bool {
        let words = lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        for index in 0..<words.count where CheckingNotesRule.isCheckingWord(words[index]) { return true }
        return false
    }
}

extension CheckingNotesRule {
    fileprivate static func isCheckingWord(_ word: String) -> Bool { checkingWords.contains(word) }
}
