import Foundation

/// The one rule for where a sentence ends, shared by the speech splitter and the answer parts, so the bubble, the
/// voice and the part boundaries always agree.
///
/// The principle: a false split shows a cut sentence in the bubble, which breaks the cursor line's main promise; a
/// missed split only delays a finished sentence until the next end mark or the end of the answer. So whenever the
/// word after an ambiguous end mark is not known yet, or is not clearly a new sentence, the sentence stays whole.
public enum SentenceRule {
    /// Words that end in a period without ending a sentence.
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "st.", "vs."]

    /// Characters that close a quotation or bracket and stay with the sentence they end.
    private static let closers: Set<Character> = [
        "\"", "'", "\u{2019}", "\u{201D}", "\u{00BB}", ")", "]",
    ]

    /// What can open the first word of a sentence after a closing quote or bracket.
    private static let sentenceOpeningCharacters: Set<Character> = [
        "\"", "'", "\u{2018}", "\u{201C}", "\u{00AB}", "(", "[",
    ]

    /// Words that start a sentence and are never the second half of a name. After a single capital letter and its
    /// period ("Plan B." "Vitamin C." "so do I.") or after an ellipsis, one of these means a new sentence started;
    /// any other word (a name such as "Kennedy") means the letter was an initial. A fixed list on purpose: a word
    /// missing from it only delays a split.
    private static let sentenceOpeners: Set<String> = [
        "I", "I'm", "I'll", "I've", "I'd", "It", "It's", "He", "She", "We", "You", "They", "This", "That", "That's",
        "These", "Those", "There", "Here", "The", "A", "An", "My", "Your", "Our", "Their", "Its",
        "Then", "Next", "Now", "Also", "But", "And", "So", "If", "When", "Once", "After", "Before", "First",
        "Second", "Third", "Finally", "Otherwise", "However", "Because", "Or",
        "Click", "Press", "Open", "Use", "Try", "Select", "Go", "Choose", "Type", "Enter", "Close", "Save", "Run",
        "Check", "Make", "See", "Note", "Tap", "Scroll", "Drag", "Copy", "Paste", "Install", "Set", "Turn", "Start",
        "Stop", "Wait", "Let", "Let's", "Please", "Do", "Don't", "Yes", "No", "Keep", "Hold", "Look", "Add", "Remove",
        "Delete", "Create", "Pick", "Move", "Restart", "Sign", "Log", "Switch", "Find", "Read", "Ask",
        "Can", "Should", "Would", "Could", "Is", "Are", "Does", "What", "Why", "How", "Which", "Who", "Where", "Just",
        "Each", "Every", "All", "Some", "For", "In", "On", "At", "To", "With", "Instead", "Still", "Only", "Maybe",
        "Sure", "Hit", "Take", "Give", "Enable", "Disable", "Update", "Launch", "Navigate", "Visit", "Download",
    ]

    /// The only words that settle an ellipsis: a sequence word or an imperative verb clearly starts a new sentence
    /// ("Wait... Then click Save."). Any other word after "..." (a pronoun, "If", "So", "When", "Maybe", a question
    /// word) usually continues the trailing-off thought ("Hmm... If you want."), so the sentence stays whole.
    private static let settlesEllipsis: Set<String> = [
        "Then", "Next", "Now", "Also", "But", "First", "Second", "Third", "Finally", "Otherwise", "However",
        "Click", "Press", "Open", "Use", "Try", "Select", "Go", "Choose", "Type", "Enter", "Close", "Save", "Run",
        "Check", "Make", "See", "Note", "Tap", "Scroll", "Drag", "Copy", "Paste", "Install", "Set", "Turn", "Start",
        "Stop", "Wait", "Let's", "Please", "Keep", "Hold", "Look", "Add", "Remove", "Delete", "Create", "Pick",
        "Move", "Restart", "Sign", "Log", "Switch", "Find", "Read", "Ask", "Hit", "Take", "Give", "Enable",
        "Disable", "Update", "Launch", "Navigate", "Visit", "Download",
    ]

    /// True when the character at `index` ends a sentence: ".", "!", "?" or "…" (then any closing quotes or
    /// brackets, which stay with the sentence) followed by whitespace, and for a period not the end of an
    /// abbreviation ("e.g.", "i.e.", "U.S.", "Dr.", "Mr.", "Mrs.", "Ms.", "St.", "vs."), a list numeral ("1." at the
    /// start of the text, after a line break or after a sentence end), or the middle of a name.
    ///
    /// These need the next word to decide, and stay whole while it is unknown: a single capital letter ("Plan B.
    /// Then ..." ends, "John F. Kennedy" does not), an ellipsis ("Wait... Then ..." ends, "Hmm... okay" does not),
    /// "etc." (ends before a capital letter) and a closing quote or bracket (ends before a capital letter). With no
    /// next word, `isTextComplete` (nothing more can follow: a hidden tag or marker comes next, or the answer is
    /// final) settles them as an end.
    public static func endsSentence(at index: Int, in characters: [Character], isTextComplete: Bool = false) -> Bool {
        guard index >= 0, index < characters.count,
              index + 1 < characters.count, characters[index + 1].isWhitespace else { return false }

        // Walk back over closing quotes and brackets to the end mark they close.
        var markIndex = index
        while markIndex > 0, closers.contains(characters[markIndex]) { markIndex -= 1 }
        let mark = characters[markIndex]
        guard ".!?\u{2026}".contains(mark) else { return false }
        let hasClosers = markIndex < index

        if mark == "\u{2026}" || (mark == "." && markIndex > 0 && characters[markIndex - 1] == ".") {
            // An ellipsis never ends a sentence by itself: only an opener word after it does.
            return nextWordIsSentenceOpener(
                after: index, in: characters, isTextComplete: isTextComplete, afterEllipsis: true)
        }
        if mark != "." {
            return !hasClosers || nextWordStartsSentence(after: index, in: characters, isTextComplete: isTextComplete)
        }

        var tokenStart = markIndex
        while tokenStart > 0, !characters[tokenStart - 1].isWhitespace { tokenStart -= 1 }
        // An opening quote or bracket is not part of the word.
        while tokenStart < markIndex, "([\"'\u{201C}\u{2018}\u{00AB}".contains(characters[tokenStart]) { tokenStart += 1 }
        let token = Array(characters[tokenStart...markIndex])
        let lowercasedToken = String(token).lowercased()

        if abbreviations.contains(lowercasedToken) { return false }
        if isDottedLetters(token) { return false }
        if token.count == 2, token[0].isLetter, token[0].isUppercase {
            // "A." as a list label ("A. Click Save. B. Click Close.") has no word before it in its clause.
            if isLabelPosition(tokenStart: tokenStart, in: characters) { return false }
            return nextWordIsSentenceOpener(after: index, in: characters, isTextComplete: isTextComplete)
        }
        if lowercasedToken == "etc." {
            return nextWordStartsSentence(after: index, in: characters, isTextComplete: isTextComplete)
        }
        if isListNumeral(token, startingAt: tokenStart, in: characters) { return false }
        return !hasClosers || nextWordStartsSentence(after: index, in: characters, isTextComplete: isTextComplete)
    }

    /// True when nothing but a bullet precedes the token in its clause: the start of the text, a line break, a
    /// sentence end, ":" or ",".
    private static func isLabelPosition(tokenStart: Int, in characters: [Character]) -> Bool {
        var before = tokenStart - 1
        // An opening quote or bracket stuck to the label is not a word.
        while before >= 0, sentenceOpeningCharacters.contains(characters[before]) { before -= 1 }
        func skipSpaces() { while before >= 0, characters[before] == " " || characters[before] == "\t" { before -= 1 } }
        skipSpaces()
        if before >= 0, "-*\u{2022}".contains(characters[before]) {
            before -= 1
            skipSpaces()
        }
        if before < 0 { return true }
        return characters[before].isNewline || ".!?\u{2026}:,".contains(characters[before])
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

    /// The word after `index`: its text, and whether whitespace (or the end of the text) already closed it. Nil when
    /// only whitespace follows.
    private static func nextWord(after index: Int, in characters: [Character]) -> (text: String, isClosed: Bool)? {
        var start = index + 1
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        guard start < characters.count else { return nil }
        var end = start
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        return (String(characters[start..<end]), end < characters.count)
    }

    /// True when the next word starts like a sentence: a capital letter, a digit or an opening quote or bracket. With
    /// no next word, the text being complete decides.
    private static func nextWordStartsSentence(after index: Int, in characters: [Character], isTextComplete: Bool) -> Bool {
        guard let word = nextWord(after: index, in: characters), let first = word.text.first else { return isTextComplete }
        return first.isUppercase || first.isNumber || sentenceOpeningCharacters.contains(first)
    }

    /// True when the next word is one of the fixed sentence openers. A word still being written never counts (its
    /// first letters may be the start of a name), and neither does another initial ("J. A. Smith"). With no next
    /// word, the text being complete decides.
    private static func nextWordIsSentenceOpener(after index: Int, in characters: [Character], isTextComplete: Bool, afterEllipsis: Bool = false) -> Bool {
        guard let word = nextWord(after: index, in: characters) else { return isTextComplete }
        if !word.isClosed && !isTextComplete { return false }
        let bare = word.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{2018}\u{2019}\u{201C}\u{201D}([\u{00AB}\u{00BB}"))
        let withoutEnd = bare.trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?)]"))
        // Another single capital letter with its period is an initial, not an opener ("J. A. Smith").
        if withoutEnd.count == 2, withoutEnd.hasSuffix("."), let letter = withoutEnd.first, letter.isUppercase { return false }
        let opener = withoutEnd.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if afterEllipsis { return settlesEllipsis.contains(opener) }
        return sentenceOpeners.contains(opener)
    }
}
