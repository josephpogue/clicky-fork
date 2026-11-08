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
        let previewStates: [(String, QuestionKeySettingsState, QuestionKeySettingsState)] = [
            // Chat key states, shown under the Question key section.
            ("settings-chat-key-default.png", QuestionKeySettingsState(), QuestionKeySettingsState(kind: .chat)),
            ("settings-chat-key-recording.png", QuestionKeySettingsState(),
             QuestionKeySettingsState(kind: .chat, isRecording: true, recordingHint: "Right Command")),
            ("settings-chat-key-overlap.png", QuestionKeySettingsState(),
             QuestionKeySettingsState(
                kind: .chat, isRecording: true,
                message: KeyOverlap.refusalForChatKey(.sidedCombination(modifiers: [.rightCommand], keyCode: nil), question: .default) ?? "")),
            ("settings-question-key-overlap.png",
             QuestionKeySettingsState(
                isRecording: true,
                message: KeyOverlap.refusalForQuestionKey(.combination(modifiers: [.command], keyCode: 43), chat: .defaultChatKey) ?? ""),
             QuestionKeySettingsState(kind: .chat)),
            ("settings-question-key-default.png", QuestionKeySettingsState(), QuestionKeySettingsState(kind: .chat)),
            ("settings-question-key-combination.png", QuestionKeySettingsState(
                currentKey: .combination(modifiers: [.control, .option], keyCode: 49)), QuestionKeySettingsState(kind: .chat)),
            ("settings-question-key-recording.png", QuestionKeySettingsState(
                isRecording: true, recordingHint: "Control + Option"), QuestionKeySettingsState(kind: .chat)),
            ("settings-question-key-rejected.png", QuestionKeySettingsState(
                isRecording: true, message: QuestionKeyRejection.needsModifier.message), QuestionKeySettingsState(kind: .chat)),
        ]
        for (fileName, questionKeyState, chatKeyState) in previewStates {
            let settingsState = SettingsState(
                providers: [UIPreviewSamples.settingsClaudeRow(isSignedIn: true), UIPreviewSamples.settingsChatGPTRow(isSignedIn: false)],
                selectedProviderName: "Claude", notesFolderPath: "/Users/sample/Notes/vault")
            try render(
                SettingsView(state: settingsState, answerDeliveryState: AnswerDeliverySettingsState(), questionKeyState: questionKeyState, chatKeyState: chatKeyState),
                size: CGSize(width: 520, height: 1200), fileName: fileName, into: directory)
        }
    }
}
