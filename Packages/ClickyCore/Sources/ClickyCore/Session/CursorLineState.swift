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
    /// What the voice says for a part whose shown line is the footer alone, so the user knows the answer is in the
    /// chat (the voice mirrors the bubble).
    public static let footerOnlySpokenSentence = "The answer is in the chat."

    /// The run measured for one part: reused while the part's complete sentences and marker are unchanged, so chat
    /// text and half-written sentences never cause a measurement.
    private struct MeasuredRun: Equatable, Sendable {
        var sentences: [String]
        var hasChatMarker: Bool
        var line: CursorLine
        var shownCount: Int
    }

    /// The sentences of each part (by part index) that were handed out to be spoken, in order.
    private var spokenSentencesByPartIndex: [Int: [String]] = [:]
    /// The parts whose footer-only line was handed out to be spoken.
    private var footerSpokenPartIndexes: Set<Int> = []
    private var measuredRunByPartIndex: [Int: MeasuredRun] = [:]
    /// The line last returned, so an update that changes nothing returns no line (the bubble is not asked to re-show).
    private var lastLine: CursorLine?
    /// The part that line came from. A line from a later part is always a change, even when it equals the last one:
    /// the search between the two parts put "Checking your notes" on the bubble, and only a returned line clears it.
    private var lastLinePartIndex: Int?

    public init() {}

    /// Returns `line` nil while no part has a whole sentence yet and whenever the line is the same as the last one
    /// returned for the same part. `newSentencesToSpeak` holds each shown sentence once; a part whose text was replaced (a provider
    /// that rewrites its text) speaks the replacing text.
    public mutating func update(parts: [AnswerPart], fits: (String) -> Bool) -> CursorLineUpdate {
        var partIndex = parts.count - 1
        while partIndex >= 0 {
            let part = parts[partIndex]
            let sentences = SpokenSentenceSplitter.sentences(
                in: part.cursorText, isTextComplete: part.isCursorTextComplete || part.endsAtSentenceEnd)
            let isFooterAloneCandidate = part.cursorText.isEmpty && part.hasChatMarker
            if !sentences.isEmpty || isFooterAloneCandidate {
                let run = measuredRun(sentences: sentences, hasChatMarker: part.hasChatMarker, partIndex: partIndex, fits: fits)
                return result(line: run.line, sentences: sentences, shownCount: run.shownCount, partIndex: partIndex)
            }
            partIndex -= 1
        }
        return CursorLineUpdate(line: nil, newSentencesToSpeak: [])
    }

    private mutating func measuredRun(
        sentences: [String], hasChatMarker: Bool, partIndex: Int, fits: (String) -> Bool
    ) -> MeasuredRun {
        if let cached = measuredRunByPartIndex[partIndex], cached.sentences == sentences, cached.hasChatMarker == hasChatMarker {
            return cached
        }
        let run = CursorLine.leadingRun(of: sentences, hasChatMarker: hasChatMarker, fits: fits)
        let measured = MeasuredRun(sentences: sentences, hasChatMarker: hasChatMarker, line: run.line, shownCount: run.shownCount)
        measuredRunByPartIndex[partIndex] = measured
        return measured
    }

    private mutating func result(
        line: CursorLine, sentences: [String], shownCount: Int, partIndex: Int
    ) -> CursorLineUpdate {
        var spoken = spokenSentencesByPartIndex[partIndex] ?? []
        if !Self.sentences(sentences, startWith: spoken) {
            // The part's text was replaced: what it says now has not been spoken.
            spoken = []
            footerSpokenPartIndexes.remove(partIndex)
        }
        var newSentences: [String] = []
        var sentenceIndex = spoken.count
        while sentenceIndex < shownCount {
            newSentences.append(sentences[sentenceIndex])
            sentenceIndex += 1
        }
        if shownCount > spoken.count { spoken = Array(sentences[0..<shownCount]) }
        spokenSentencesByPartIndex[partIndex] = spoken
        if line.text.isEmpty, line.hasMoreInChat, !footerSpokenPartIndexes.contains(partIndex) {
            footerSpokenPartIndexes.insert(partIndex)
            newSentences.append(Self.footerOnlySpokenSentence)
        }
        let isChange = line != lastLine || partIndex != lastLinePartIndex
        lastLine = line
        lastLinePartIndex = partIndex
        return CursorLineUpdate(line: isChange ? line : nil, newSentencesToSpeak: newSentences)
    }

    private static func sentences(_ sentences: [String], startWith prefix: [String]) -> Bool {
        guard sentences.count >= prefix.count else { return false }
        var index = 0
        while index < prefix.count {
            if sentences[index] != prefix[index] { return false }
            index += 1
        }
        return true
    }
}
