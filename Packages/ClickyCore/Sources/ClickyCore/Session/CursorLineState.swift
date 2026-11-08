import Foundation

/// What the bubble beside the cursor shows of an answer or a notice: whole sentences only, never cut.
public struct CursorLine: Equatable, Sendable {
    /// The whole sentences shown. Empty means the bubble is the footer line alone (nothing fitted).
    public var text: String
    /// True when the chat window holds more of this answer than the bubble shows: the footer shows.
    public var hasMoreInChat: Bool

    public init(text: String, hasMoreInChat: Bool) {
        self.text = text
        self.hasMoreInChat = hasMoreInChat
    }

    /// The line for a notice (a failed Start, a provider error, the usage limit): the same no-cut rule, all of
    /// its text complete.
    public static func notice(text: String, fits: (String) -> Bool) -> CursorLine {
        let sentences = SpokenSentenceSplitter.sentences(in: text, isTextComplete: true)
        return leadingRun(of: sentences, hasChatMarker: false, fits: fits).line
    }

    /// The longest leading run of `sentences`, joined with single spaces, that `fits`. `shownCount` is how many
    /// sentences the line holds. With no run that fits, the line is the footer alone.
    static func leadingRun(
        of sentences: [String], hasChatMarker: Bool, fits: (String) -> Bool
    ) -> (line: CursorLine, shownCount: Int) {
        var shownCount = 0
        var shownText = ""
        var sentenceIndex = 0
        while sentenceIndex < sentences.count {
            let candidateText = shownCount == 0 ? sentences[sentenceIndex] : shownText + " " + sentences[sentenceIndex]
            if !fits(candidateText) { break }
            shownText = candidateText
            shownCount += 1
            sentenceIndex += 1
        }
        let leftSomeOut = shownCount < sentences.count
        let hasMoreInChat = hasChatMarker || leftSomeOut || shownCount == 0
        return (CursorLine(text: shownText, hasMoreInChat: hasMoreInChat), shownCount)
    }
}

/// One step of an answer's cursor line.
public struct CursorLineUpdate: Equatable, Sendable {
    /// What the bubble shows now; nil while no whole sentence is known yet (the bubble shows nothing new).
    public var line: CursorLine?
    /// Sentences the bubble shows for the first time with this update, in order: the only text read aloud.
    public var newSentencesToSpeak: [String]

    public init(line: CursorLine?, newSentencesToSpeak: [String]) {
        self.line = line
        self.newSentencesToSpeak = newSentencesToSpeak
    }
}

/// Decides, from an answer's parts, which whole sentences show beside the cursor and which are read aloud.
/// Pure: `fits` is the app's measurement (true when the text fits under `CursorBubbleLayout.maximumBodyHeight`).
/// The coordinator keeps one per answer, made fresh at each question, and calls `update` after every report.
public struct CursorLineState: Equatable, Sendable {
    /// How many sentences of each part (by part index) were handed out to be spoken already.
    private var spokenSentenceCountByPartIndex: [Int: Int] = [:]
    /// The line last returned, so an update that changes nothing returns no line (the bubble is not asked to re-show).
    private var lastLine: CursorLine?

    public init() {}

    /// Returns `line` nil while no part has a whole sentence yet and whenever the line is the same as the last one
    /// returned. `newSentencesToSpeak` holds each shown sentence once, ever.
    public mutating func update(parts: [AnswerPart], fits: (String) -> Bool) -> CursorLineUpdate {
        var partIndex = parts.count - 1
        while partIndex >= 0 {
            let part = parts[partIndex]
            let sentences = SpokenSentenceSplitter.sentences(in: part.cursorText, isTextComplete: part.isCursorTextComplete)
            let isFooterAloneCandidate = part.cursorText.isEmpty && part.hasChatMarker
            if !sentences.isEmpty || isFooterAloneCandidate {
                let run = CursorLine.leadingRun(of: sentences, hasChatMarker: part.hasChatMarker, fits: fits)
                return result(line: run.line, shownSentences: sentences, shownCount: run.shownCount, partIndex: partIndex)
            }
            partIndex -= 1
        }
        return CursorLineUpdate(line: nil, newSentencesToSpeak: [])
    }

    private mutating func result(
        line: CursorLine, shownSentences: [String], shownCount: Int, partIndex: Int
    ) -> CursorLineUpdate {
        let alreadySpokenCount = spokenSentenceCountByPartIndex[partIndex] ?? 0
        var newSentences: [String] = []
        var sentenceIndex = alreadySpokenCount
        while sentenceIndex < shownCount {
            newSentences.append(shownSentences[sentenceIndex])
            sentenceIndex += 1
        }
        spokenSentenceCountByPartIndex[partIndex] = max(alreadySpokenCount, shownCount)
        let isChange = line != lastLine
        lastLine = line
        return CursorLineUpdate(line: isChange ? line : nil, newSentencesToSpeak: newSentences)
    }
}
