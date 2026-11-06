//
//  SpokenAnswerPlayer.swift
//  leanring-buddy
//
//  Reads an answer aloud with a voice built into macOS, the one picked in
//  Settings. No paid or network voice service.
//
//  SessionCoordinator calls it; it reports start and end through `onSpeakingChanged`.
//

import AVFoundation
import ClickyCore

/// Lists the voices macOS has, as the plain values `SpokenVoiceChoice` works on. Shared by the player and
/// the Settings voice menu so both pick from the same list.
enum InstalledSpokenVoices {
    static func listedVoices() -> [ListedSpokenVoice] {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { voice in
            SpokenVoiceCandidate(
                identifier: voice.identifier,
                name: voice.name,
                languageCode: voice.language,
                quality: quality(of: voice),
                isNovelty: voice.voiceTraits.contains(.isNoveltyVoice)
            )
        }
        return SpokenVoiceChoice.listedVoices(
            from: candidates,
            userLanguageCode: SpokenVoiceChoice.userLanguageCode(for: Locale.current))
    }

    /// The voice to read with: the saved one when it is still installed and listed, else the first listed
    /// voice, else macOS's default voice.
    static func voice(savedIdentifier: String?) -> AVSpeechSynthesisVoice? {
        let chosenVoice = SpokenVoiceChoice.chosenVoice(savedIdentifier: savedIdentifier, listedVoices: listedVoices())
        if let chosenVoice, let voice = AVSpeechSynthesisVoice(identifier: chosenVoice.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: nil)
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> SpokenVoiceQuality {
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }
}

/// The one place that speaks. The session's answers and Settings' sample both go through it, so only one
/// voice talks at a time; `SpeechTurnTracker` (ClickyCore) decides who is reported as speaking.
@MainActor
final class SpeechOwner {
    static let shared = SpeechOwner()

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBridge = SpeechDelegateBridge()
    private var tracker = SpeechTurnTracker()
    /// Each utterance still alive, with its reading token, until its finish or cancel arrives.
    private var liveUtterances: [ObjectIdentifier: (utterance: AVSpeechUtterance, token: Int)] = [:]
    private var speakingHandlers: [SpeechSpeaker: (Bool) -> Void] = [:]

    private init() {
        synthesizer.delegate = delegateBridge
        delegateBridge.onUtteranceEvent = { [weak self] utterance, isSpeaking in
            self?.handleUtteranceEvent(utterance: utterance, isSpeaking: isSpeaking)
        }
    }

    /// `handler` hears true when `speaker` starts speaking and false when it ends, is stopped or is replaced.
    func setSpeakingHandler(for speaker: SpeechSpeaker, _ handler: @escaping (Bool) -> Void) {
        speakingHandlers[speaker] = handler
    }

    /// Reads `text` as `speaker`, stopping whatever was being read, whoever read it.
    func speak(text: String, voice: AVSpeechSynthesisVoice?, as speaker: SpeechSpeaker) {
        synthesizer.stopSpeaking(at: .immediate)
        let reading = tracker.begin(speaker, reportsImmediately: speaker == .sample)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        liveUtterances[ObjectIdentifier(utterance)] = (utterance, reading.token)
        apply(reading.changes)
        synthesizer.speak(utterance)
    }

    /// Stops the reading when `speaker` is the one reading; a reading by the other speaker plays on.
    func stop(_ speaker: SpeechSpeaker) {
        guard tracker.currentSpeaker == speaker else { return }
        let changes = tracker.stop(speaker)
        synthesizer.stopSpeaking(at: .immediate)
        apply(changes)
    }

    /// Stops whoever is reading, the Settings sample included: a new question must not be heard over.
    func stopAll() {
        let changes = tracker.stopAll()
        synthesizer.stopSpeaking(at: .immediate)
        apply(changes)
    }

    private func handleUtteranceEvent(utterance: AVSpeechUtterance, isSpeaking: Bool) {
        guard let live = liveUtterances[ObjectIdentifier(utterance)] else { return }
        if !isSpeaking { liveUtterances[ObjectIdentifier(utterance)] = nil }
        apply(tracker.event(token: live.token, isSpeaking: isSpeaking))
    }

    private func apply(_ changes: [SpeechChange]) {
        for change in changes { speakingHandlers[change.speaker]?(change.isSpeaking) }
    }
}

@MainActor
final class SpokenAnswerPlayer {
    /// Called with true when reading starts and false when it ends, is stopped or fails.
    var onSpeakingChanged: ((Bool) -> Void)? {
        didSet {
            let handler = onSpeakingChanged
            SpeechOwner.shared.setSpeakingHandler(for: .answer) { isSpeaking in handler?(isSpeaking) }
        }
    }

    /// Reads `text` aloud, stopping anything still being read first (a Settings sample included).
    func speak(text: String) {
        // Read fresh each time so a voice picked in Settings applies to the next answer.
        let voice = InstalledSpokenVoices.voice(savedIdentifier: AppSettings.shared.spokenAnswerVoiceIdentifier)
        SpeechOwner.shared.speak(text: text, voice: voice, as: .answer)
    }

    /// Stops every voice at once, the Settings sample too: a new question.
    func stopAllSpeaking() {
        SpeechOwner.shared.stopAll()
    }

    /// Stops reading at once: Start, question, Start, Stop, Quit and a change to a mode that does not speak.
    func stopSpeaking() {
        SpeechOwner.shared.stop(.answer)
    }
}

/// AVSpeechSynthesizer calls its delegate off the main actor; this hops each event back to it.
private final class SpeechDelegateBridge: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onUtteranceEvent: (@MainActor (AVSpeechUtterance, Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        send(utterance, isSpeaking: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        send(utterance, isSpeaking: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        send(utterance, isSpeaking: false)
    }

    private func send(_ utterance: AVSpeechUtterance, isSpeaking: Bool) {
        nonisolated(unsafe) let sentUtterance = utterance
        Task { @MainActor [weak self] in
            self?.onUtteranceEvent?(sentUtterance, isSpeaking)
        }
    }
}
