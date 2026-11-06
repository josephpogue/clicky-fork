//
//  UIPreviewRendering+AnswerDeliverySettings.swift
//  leanring-buddy
//
//  Preview PNGs for the Showing answers section of Settings (spoken-answers slice).
//

import AppKit
import ClickyCore
import SwiftUI

extension UIPreviewRendering {
    @MainActor
    static func renderAnswerDeliverySettingsPreviews(into directory: URL) throws {
        // Fixed voices, so the PNGs do not depend on what this Mac has installed.
        let sampleVoices = [
            AnswerVoiceMenuItem(identifier: "sample.zoe", displayName: "Zoe (Premium)"),
            AnswerVoiceMenuItem(identifier: "sample.ava", displayName: "Ava (Enhanced)"),
            AnswerVoiceMenuItem(identifier: "sample.samantha", displayName: "Samantha"),
        ]
        let settingsWindowSize = CGSize(width: 520, height: 900)
        let previewStates: [(String, AnswerDeliveryMode, Bool)] = [
            ("settings-answer-by-text.png", .text, false),
            ("settings-answer-by-spoken.png", .spoken, false),
            ("settings-answer-by-both.png", .both, false),
            ("settings-answer-by-both-playing.png", .both, true),
        ]
        for (fileName, mode, isPlayingSample) in previewStates {
            let answerDeliveryState = AnswerDeliverySettingsState(
                selectedMode: mode, voices: sampleVoices, selectedVoiceIdentifier: "sample.zoe", isPlayingSample: isPlayingSample)
            let settingsState = SettingsState(
                providers: [UIPreviewSamples.settingsClaudeRow(isSignedIn: true), UIPreviewSamples.settingsChatGPTRow(isSignedIn: false)],
                selectedProviderName: "Claude", notesFolderPath: "/Users/sample/Notes/vault")
            try render(
                SettingsView(state: settingsState, answerDeliveryState: answerDeliveryState),
                size: settingsWindowSize, fileName: fileName, into: directory)
        }
    }
}
