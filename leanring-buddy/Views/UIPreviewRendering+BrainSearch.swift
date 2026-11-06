//
//  UIPreviewRendering+BrainSearch.swift
//  leanring-buddy
//
//  Preview PNGs for answers that search the user's notes (brain-context designer slice): the two Settings
//  sections, and the chat with an answer still coming and with a Notes read list. The growing bubble beside
//  the cursor is in `UIPreviewRendering+CursorAnswers.swift`. All folders and file names are made up.
//

import ClickyCore
import SwiftUI

extension UIPreviewRendering {
    @MainActor
    static func renderBrainSearchPreviews(into directory: URL) throws {
        // Tall enough to show the dig-deeper and folder sections below the provider cards.
        let tallSettingsSize = CGSize(width: 520, height: 1420)
        for (fileName, settingsState) in BrainSearchPreviewSamples.settingsStates() {
            try render(SettingsView(state: settingsState), size: tallSettingsSize, fileName: fileName, into: directory)
        }

        let chatWindowSize = CGSize(width: 360, height: 520)
        for (fileName, chatState) in BrainSearchPreviewSamples.chatStates() {
            // The checking line's light is frozen mid-sweep so every render shows it the same way.
            try render(ChatWindowView(state: chatState, fixedCheckingSweepPhase: 0.55), size: chatWindowSize, fileName: fileName, into: directory)
        }
    }
}

@MainActor
enum BrainSearchPreviewSamples {
    private static let home = NSHomeDirectory()

    static func settingsStates() -> [(String, SettingsState)] {
        let providers = [UIPreviewSamples.settingsClaudeRow(isSignedIn: true), UIPreviewSamples.settingsChatGPTRow(isSignedIn: true)]
        let threeFolders = ["\(home)/notes", "\(home)/projects", "\(home)/Documents/work/team-handbook"]
        let signedInDigDeeperRows = [
            DigDeeperModelRow(providerName: "Claude", models: ["sonnet", "opus", "haiku"], selectedModel: "opus"),
            DigDeeperModelRow(providerName: "ChatGPT", models: ["", "gpt-5", "gpt-5-codex", "gpt-5-mini"], selectedModel: ""),
        ]
        func settings(paths: [String], status: SearchFolderIndexStatus?, rows: [DigDeeperModelRow] = signedInDigDeeperRows) -> SettingsState {
            SettingsState(
                providers: providers, selectedProviderName: "Claude", notesFolderPath: "/Users/sample/Notes/vault",
                searchFolderPaths: paths, searchFolderIndexStatus: status, digDeeperModelRows: rows)
        }
        return [
            ("settings-search-folders-empty.png", settings(paths: [], status: nil, rows: DigDeeperModelRow.defaultRows)),
            ("settings-search-folders-three.png", settings(paths: threeFolders, status: SearchFolderIndexStatus(text: "1,284 notes indexed"))),
            ("settings-search-folders-indexing.png", settings(paths: threeFolders, status: SearchFolderIndexStatus(text: "Indexing...", kind: .working))),
            ("settings-search-folders-problem.png", settings(
                paths: threeFolders,
                status: SearchFolderIndexStatus(text: "Could not read ~/Documents/work/team-handbook", kind: .problem))),
            ("settings-dig-deeper-chatgpt-signed-out.png", settings(
                paths: threeFolders, status: SearchFolderIndexStatus(text: "1,284 notes indexed"),
                rows: [signedInDigDeeperRows[0], DigDeeperModelRow(providerName: "ChatGPT", models: [], selectedModel: "")])),
        ]
    }

    private static let sessionStart = Date().addingTimeInterval(-25 * 60)

    private static func minutesIntoSession(_ minutes: Double) -> Date {
        sessionStart.addingTimeInterval(minutes * 60)
    }

    private static var earlierExchange: [ChatMessage] {
        [
            ChatMessage(role: .question, text: "what's this error in the terminal", time: minutesIntoSession(3)),
            ChatMessage(
                role: .answer,
                text: "The server could not bind its port because another process is using it. Quit the other server or free the port, then start again.",
                time: minutesIntoSession(3.05), providerName: "Claude", model: "sonnet", secondsToAnswer: 2.2),
        ]
    }

    private static var portQuestion: ChatMessage {
        ChatMessage(role: .question, text: "which port does the demo server use, per my notes", time: minutesIntoSession(9))
    }

    private static let finishedPortAnswer = "Your notes say the demo server uses port 4100, fixed on purpose because the browser extension posts to it. Start it from the demo-server folder with npm run dev."

    private static let twoNotes = ["\(home)/notes/demo-server.md", "\(home)/projects/demo/deploy-checklist.md"]
    private static let sevenNotes = [
        "\(home)/notes/demo-server.md",
        "\(home)/projects/demo/deploy-checklist.md",
        "\(home)/notes/ports.md",
        "\(home)/notes/browser-extension.md",
        "\(home)/projects/demo/README.md",
        "\(home)/notes/2026-10-28-standup.md",
        "\(home)/Documents/work/team-handbook/local-servers-and-the-ports-they-hold.md",
    ]

    static func chatStates() -> [(String, ChatWindowState)] {
        let waitingPhase = QuestionPhase.waitingForAnswer(providerName: "Claude")
        return [
            ("chat-checking-before-text.png", ChatWindowState(
                messages: earlierExchange + [portQuestion], sessionPhase: .running, questionPhase: waitingPhase, isCheckingNotes: true)),
            ("chat-answer-still-coming-checking.png", ChatWindowState(
                messages: earlierExchange + [portQuestion, ChatMessage(
                    role: .answer, text: "Your notes say the demo server uses port 4100.",
                    time: minutesIntoSession(9.02), providerName: "Claude", model: "sonnet", isStillComing: true)],
                sessionPhase: .running, questionPhase: waitingPhase, isCheckingNotes: true)),
            ("chat-answer-still-coming.png", ChatWindowState(
                messages: earlierExchange + [portQuestion, ChatMessage(
                    role: .answer, text: "Your notes say the demo server uses port 4100, fixed on purpose because the browser extension posts to",
                    time: minutesIntoSession(9.02), providerName: "Claude", model: "sonnet", isStillComing: true)],
                sessionPhase: .running, questionPhase: waitingPhase)),
            ("chat-notes-read-two.png", ChatWindowState(
                messages: earlierExchange + [portQuestion, ChatMessage(
                    role: .answer, text: finishedPortAnswer, time: minutesIntoSession(9.1),
                    providerName: "Claude", model: "sonnet", secondsToAnswer: 3.4, notesRead: twoNotes)],
                sessionPhase: .running)),
            ("chat-notes-read-seven.png", ChatWindowState(
                messages: earlierExchange + [portQuestion, ChatMessage(
                    role: .answer, text: finishedPortAnswer, time: minutesIntoSession(9.1),
                    providerName: "Claude", model: "sonnet", secondsToAnswer: 6.9, pointLabel: "Terminal tab", notesRead: sevenNotes)],
                sessionPhase: .running)),
            ("chat-notes-read-in-history.png", ChatWindowState(
                messages: earlierExchange + [portQuestion, ChatMessage(
                    role: .answer, text: finishedPortAnswer, time: minutesIntoSession(9.1),
                    providerName: "Claude", model: "sonnet", secondsToAnswer: 3.4, notesRead: sevenNotes),
                    ChatMessage(role: .question, text: "where's the start button", time: minutesIntoSession(12)),
                    ChatMessage(
                        role: .answer, text: "Top left of the panel, the green triangle. I've pointed at it.",
                        time: minutesIntoSession(12.03), providerName: "Claude", model: "sonnet", secondsToAnswer: 1.9, pointLabel: "Run"),
                ],
                sessionPhase: .running)),
        ]
    }
}
