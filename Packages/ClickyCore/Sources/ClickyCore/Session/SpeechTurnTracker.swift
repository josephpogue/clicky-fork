import Foundation

/// Who is using the Mac's one voice: the session reading an answer, or the Settings sample.
public enum SpeechSpeaker: Sendable, Equatable {
    case answer
    case sample
}

/// A speaker's "is speaking" report changed: the capsule shows or hides, the sample button flips.
public struct SpeechChange: Sendable, Equatable {
    public let speaker: SpeechSpeaker
    public let isSpeaking: Bool

    public init(speaker: SpeechSpeaker, isSpeaking: Bool) {
        self.speaker = speaker
        self.isSpeaking = isSpeaking
    }
}

/// Keeps one reading at a time and decides what to report. Every reading gets a token; events for any other
/// token (an older reading that was stopped or replaced) are ignored, and a start or stop is reported once.
public struct SpeechTurnTracker: Sendable {
    public private(set) var currentSpeaker: SpeechSpeaker?
    private var currentToken: Int?
    private var isReportedSpeaking = false
    private var nextToken = 0
    private var endedSpeaker: SpeechSpeaker?

    public init() {}

    /// Starts a reading, replacing any other. `changes` ends the replaced reading's report first.
    /// `reportsImmediately` reports "speaking" now (the sample button flips at the press) instead of at the
    /// first start event (the speaker capsule shows when the voice actually begins).
    public mutating func begin(_ speaker: SpeechSpeaker, reportsImmediately: Bool = false) -> (token: Int, changes: [SpeechChange]) {
        var changes = endCurrentReport()
        nextToken += 1
        currentToken = nextToken
        currentSpeaker = speaker
        if reportsImmediately {
            isReportedSpeaking = true
            changes.append(SpeechChange(speaker: speaker, isSpeaking: true))
        }
        return (nextToken, changes)
    }

    /// Stops the current reading, or only when `speaker` is the one reading (nil stops whoever it is).
    public mutating func stop(_ speaker: SpeechSpeaker? = nil) -> [SpeechChange] {
        guard let currentSpeaker, speaker == nil || speaker == currentSpeaker else { return [] }
        let changes = endCurrentReport()
        return changes
    }

    /// Stops whoever is reading: a new question silences the sample as well as the answer.
    public mutating func stopAll() -> [SpeechChange] {
        stop(nil)
    }

    /// A start, finish or cancel event from the synthesizer for the reading with `token`.
    public mutating func event(token: Int, isSpeaking: Bool) -> [SpeechChange] {
        guard token == currentToken, let speaker = currentSpeaker else { return [] }
        if isSpeaking {
            guard !isReportedSpeaking else { return [] }
            isReportedSpeaking = true
            return [SpeechChange(speaker: speaker, isSpeaking: true)]
        }
        return endCurrentReport()
    }

    /// Which speaker's reading ended since the last call, whether or not the voice ever reported "speaking": a queued
    /// sentence cancelled or finished with no start event, and a stop before the voice began, end a reading with no
    /// speaking change. Whoever must react to a reading's end (the deferred cursor notice) asks here after each call
    /// that can end one (`begin`, `stop`, `stopAll`, `event`). Reading it clears it.
    public mutating func takeEndedReading() -> SpeechSpeaker? {
        defer { endedSpeaker = nil }
        return endedSpeaker
    }

    private mutating func endCurrentReport() -> [SpeechChange] {
        if let speaker = currentSpeaker { endedSpeaker = speaker }
        defer {
            currentToken = nil
            currentSpeaker = nil
            isReportedSpeaking = false
        }
        guard let speaker = currentSpeaker, isReportedSpeaking else { return [] }
        return [SpeechChange(speaker: speaker, isSpeaking: false)]
    }
}
