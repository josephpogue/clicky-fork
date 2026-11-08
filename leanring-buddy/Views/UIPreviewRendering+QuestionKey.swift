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
            ("settings-chat-key-inactive.png",
             QuestionKeySettingsState(currentKey: .combination(modifiers: [.command], keyCode: 43)),
             QuestionKeySettingsState(
                kind: .chat,
                inactiveNotice: KeyOverlap.inactiveChatKeyNotice(
                    chat: .defaultChatKey, question: .combination(modifiers: [.command], keyCode: 43)) ?? "")),
            ("settings-question-key-overlap.png",
             QuestionKeySettingsState(
                isRecording: true,
                message: KeyOverlap.refusalForQuestionKey(.combination(modifiers: [.command], keyCode: 43), chat: .defaultChatKey) ?? ""),
             QuestionKeySettingsState(kind: .chat)),
            // The key tap was lost in a running session: both keys say so until the next Start or Stop.
            ("settings-keys-tap-lost.png",
             QuestionKeySettingsState(tapLostNotice: KeyTapNotice.settingsLine(keyName: "question key")),
             QuestionKeySettingsState(kind: .chat, tapLostNotice: KeyTapNotice.settingsLine(keyName: "chat key"))),
            // Reset pressed on the chat key while its default would clash with the question key.
            ("settings-chat-key-reset-refused.png",
             QuestionKeySettingsState(currentKey: .combination(modifiers: [.command], keyCode: 43)),
             QuestionKeySettingsState(
                kind: .chat, currentKey: .sidedCombination(modifiers: [.rightOption], keyCode: nil),
                message: KeyOverlap.resetRefusalForChatKey(
                    .defaultChatKey, question: .combination(modifiers: [.command], keyCode: 43)) ?? "")),
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
