//
//  UIPreviewRendering+QuestionKey.swift
//  leanring-buddy
//
//  Preview PNGs for the Question key section of Settings.
//

import AppKit
import ClickyCore
import SwiftUI

extension UIPreviewRendering {
    @MainActor
    static func renderQuestionKeyPreviews(into directory: URL) throws {
        let previewStates: [(String, QuestionKeySettingsState)] = [
            ("settings-question-key-default.png", QuestionKeySettingsState()),
            ("settings-question-key-combination.png", QuestionKeySettingsState(
                currentKey: .combination(modifiers: [.control, .option], keyCode: 49))),
            ("settings-question-key-recording.png", QuestionKeySettingsState(
                isRecording: true, recordingHint: "Control + Option")),
            ("settings-question-key-rejected.png", QuestionKeySettingsState(
                isRecording: true, message: QuestionKeyRejection.needsModifier.message)),
        ]
        for (fileName, questionKeyState) in previewStates {
            let settingsState = SettingsState(
                providers: [UIPreviewSamples.settingsClaudeRow(isSignedIn: true), UIPreviewSamples.settingsChatGPTRow(isSignedIn: false)],
                selectedProviderName: "Claude", notesFolderPath: "/Users/sample/Notes/vault")
            try render(
                SettingsView(state: settingsState, answerDeliveryState: AnswerDeliverySettingsState(), questionKeyState: questionKeyState),
                size: CGSize(width: 520, height: 1000), fileName: fileName, into: directory)
        }
    }
}
