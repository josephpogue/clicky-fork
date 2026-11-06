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
            userLanguageCode: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
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

@MainActor
final class SpokenAnswerPlayer {
    /// Called with true when reading starts and false when it ends, is stopped or fails.
    var onSpeakingChanged: ((Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBridge = SpeechDelegateBridge()
    /// The utterance that counts. Callbacks for any other (an older one stopped by a new question) are ignored,
    /// so a stop followed at once by a new speak never ends with "not speaking".
    private var currentUtterance: AVSpeechUtterance?
    private var isReportedSpeaking = false

    init() {
        synthesizer.delegate = delegateBridge
        delegateBridge.onUtteranceEvent = { [weak self] utterance, isSpeaking in
            self?.handleUtteranceEvent(utterance: utterance, isSpeaking: isSpeaking)
        }
    }

    /// Reads `text` aloud, stopping anything still being read first.
    func speak(text: String) {
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)
        // Read fresh each time so a voice picked in Settings applies to the next answer.
        utterance.voice = InstalledSpokenVoices.voice(savedIdentifier: AppSettings.shared.spokenAnswerVoiceIdentifier)
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// Stops reading at once: a new question, Start, Stop and Quit.
    func stopSpeaking() {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        reportSpeaking(false)
    }

    private func handleUtteranceEvent(utterance: AVSpeechUtterance, isSpeaking: Bool) {
        guard utterance === currentUtterance else { return }
        if !isSpeaking { currentUtterance = nil }
        reportSpeaking(isSpeaking)
    }

    private func reportSpeaking(_ isSpeaking: Bool) {
        guard isSpeaking != isReportedSpeaking else { return }
        isReportedSpeaking = isSpeaking
        onSpeakingChanged?(isSpeaking)
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
