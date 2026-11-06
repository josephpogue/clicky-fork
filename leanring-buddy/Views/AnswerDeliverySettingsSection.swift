//
//  AnswerDeliverySettingsSection.swift
//  leanring-buddy
//
//  The "Showing answers" section of Settings: Text, Spoken or Both, and for
//  Spoken or Both a Mac voice menu with a sample button.
//

import AVFoundation
import Combine
import ClickyCore
import SwiftUI

/// One voice in the menu: the identifier AppSettings saves and the name the user sees.
struct AnswerVoiceMenuItem: Identifiable, Equatable {
    let identifier: String
    let displayName: String
    var id: String { identifier }
}

@MainActor
final class AnswerDeliverySettingsState: ObservableObject {
    @Published var selectedMode: AnswerDeliveryMode
    @Published var voices: [AnswerVoiceMenuItem]
    /// The identifier of the voice shown on the menu button; nil when the Mac has no listed voice.
    @Published var selectedVoiceIdentifier: String?
    @Published var isPlayingSample: Bool

    var onSelectMode: (_ mode: AnswerDeliveryMode) -> Void
    var onSelectVoice: (_ voiceIdentifier: String) -> Void
    var onToggleSample: () -> Void

    init(
        selectedMode: AnswerDeliveryMode = .text,
        voices: [AnswerVoiceMenuItem] = [],
        selectedVoiceIdentifier: String? = nil,
        isPlayingSample: Bool = false,
        onSelectMode: @escaping (AnswerDeliveryMode) -> Void = { _ in },
        onSelectVoice: @escaping (String) -> Void = { _ in },
        onToggleSample: @escaping () -> Void = {}
    ) {
        self.selectedMode = selectedMode
        self.voices = voices
        self.selectedVoiceIdentifier = selectedVoiceIdentifier
        self.isPlayingSample = isPlayingSample
        self.onSelectMode = onSelectMode
        self.onSelectVoice = onSelectVoice
        self.onToggleSample = onToggleSample
    }

    /// The name on the voice button: the chosen voice's display name, or "Mac voice" when none is listed.
    var selectedVoiceDisplayName: String {
        voices.first(where: { $0.identifier == selectedVoiceIdentifier })?.displayName ?? "Mac voice"
    }
}

/// Wires `AnswerDeliverySettingsState` to AppSettings and to the shared `SpeechOwner`, so the sample and a
/// session answer never talk over each other.
@MainActor
final class AnswerDeliverySettingsController {
    static let sampleSentence = "This is how answers will sound."

    let state: AnswerDeliverySettingsState
    private var windowCloseObserver: NSObjectProtocol?

    init() {
        state = AnswerDeliverySettingsState()
        SpeechOwner.shared.setSpeakingHandler(for: .sample) { [weak self] isSpeaking in
            self?.state.isPlayingSample = isSpeaking
        }
        // Closing the Settings window stops the sample (the window is kept and reused, so no view goes away).
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "settings.nswindow" else { return }
            Task { @MainActor in self?.stopSample() }
        }
        state.onSelectMode = { [weak self] mode in
            // Applies from the next answer: the session reads the mode when an answer arrives.
            AppSettings.shared.answerDeliveryMode = mode
            self?.state.selectedMode = mode
            // The voice row (and the sample button) goes away with the spoken modes.
            if !mode.speaksAloud { self?.stopSample() }
        }
        state.onSelectVoice = { [weak self] voiceIdentifier in
            AppSettings.shared.spokenAnswerVoiceIdentifier = voiceIdentifier
            self?.stopSample()
            self?.reloadFromSettings()
        }
        state.onToggleSample = { [weak self] in self?.toggleSample() }
        reloadFromSettings()
    }

    deinit {
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    /// Re-reads the mode, the installed voices and the saved voice; called when Settings opens.
    func reloadFromSettings() {
        let listedVoices = InstalledSpokenVoices.listedVoices()
        state.voices = listedVoices.map { AnswerVoiceMenuItem(identifier: $0.identifier, displayName: $0.displayName) }
        state.selectedVoiceIdentifier = SpokenVoiceChoice.chosenVoice(
            savedIdentifier: AppSettings.shared.spokenAnswerVoiceIdentifier, listedVoices: listedVoices)?.identifier
        state.selectedMode = AppSettings.shared.answerDeliveryMode
    }

    func stopSample() {
        SpeechOwner.shared.stop(.sample)
        state.isPlayingSample = false
    }

    private func toggleSample() {
        if state.isPlayingSample {
            stopSample()
            return
        }
        // The sample uses the voice the menu shows, not a stale saved one. Starting it stops an answer being read.
        let voice = InstalledSpokenVoices.voice(savedIdentifier: state.selectedVoiceIdentifier)
        SpeechOwner.shared.speak(text: Self.sampleSentence, voice: voice, as: .sample)
    }
}

struct AnswerDeliverySettingsSection: View {
    @ObservedObject var state: AnswerDeliverySettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Showing answers")
                    .font(DS.WindowText.windowTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Text sits beside the cursor and goes away when you click or type.\nSpoken reads the answer aloud with a Mac voice.")
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Answer by")
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 72, alignment: .leading)
                HStack(spacing: 6) {
                    modePill(title: "Text", mode: .text, slug: "text")
                    modePill(title: "Spoken", mode: .spoken, slug: "spoken")
                    modePill(title: "Both", mode: .both, slug: "both")
                }
                .accessibilityElement(children: .contain)
            }

            if state.selectedMode.speaksAloud {
                voiceRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.answerBy")
    }

    private func modePill(title: String, mode: AnswerDeliveryMode, slug: String) -> some View {
        WindowChoicePill(
            title: title,
            isSelected: state.selectedMode == mode,
            action: { state.onSelectMode(mode) }
        )
        .accessibilityValue(state.selectedMode == mode ? "selected" : "not selected")
        .accessibilityIdentifier("settings.answerBy.\(slug)")
    }

    private var voiceRow: some View {
        HStack(spacing: 10) {
            Text("Voice")
                .font(DS.WindowText.body)
                .foregroundColor(DS.Colors.textSecondary)
                // Same left edge as the Answer by pills: the label column is as wide as "Answer by".
                .frame(width: 72, alignment: .leading)

            Menu {
                ForEach(state.voices) { voice in
                    Button(voice.displayName) { state.onSelectVoice(voice.identifier) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(state.selectedVoiceDisplayName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .clickyWindowButton(.secondary, isCompact: true)
            .fixedSize()
            .disabled(state.voices.isEmpty)
            .accessibilityValue(state.selectedVoiceDisplayName)
            .accessibilityIdentifier("settings.voice")

            Button(action: state.onToggleSample) {
                HStack(spacing: 6) {
                    Image(systemName: state.isPlayingSample ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(state.isPlayingSample ? "Stop" : "Play sample")
                }
            }
            .clickyWindowButton(.secondary, isCompact: true)
            .accessibilityIdentifier("settings.playSample")
        }
    }
}
