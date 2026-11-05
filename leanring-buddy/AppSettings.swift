//
//  AppSettings.swift
//  leanring-buddy
//
//  The user's choices, saved in UserDefaults so they survive a restart.
//  No path or account is built in: the notes folder starts empty.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let userDefaults: UserDefaults

    @Published var selectedProvider: ProviderID {
        didSet { userDefaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    /// Model name passed to the Claude CLI's model option.
    @Published var claudeModel: String {
        didSet { userDefaults.set(claudeModel, forKey: Keys.claudeModel) }
    }

    /// Model name passed to the Codex CLI. Empty means the CLI's own default.
    @Published var chatgptModel: String {
        didSet { userDefaults.set(chatgptModel, forKey: Keys.chatgptModel) }
    }

    /// Folder where a saved session's notes are written. Nil until the user picks one.
    @Published var notesFolderPath: String? {
        didSet { userDefaults.set(notesFolderPath, forKey: Keys.notesFolderPath) }
    }

    @Published var summaryAtStopEnabled: Bool {
        didSet { userDefaults.set(summaryAtStopEnabled, forKey: Keys.summaryAtStopEnabled) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        selectedProvider = userDefaults.string(forKey: Keys.selectedProvider).flatMap(ProviderID.init(rawValue:)) ?? .claude
        claudeModel = userDefaults.string(forKey: Keys.claudeModel) ?? "sonnet"
        chatgptModel = userDefaults.string(forKey: Keys.chatgptModel) ?? ""
        notesFolderPath = userDefaults.string(forKey: Keys.notesFolderPath)
        summaryAtStopEnabled = userDefaults.object(forKey: Keys.summaryAtStopEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let selectedProvider = "settings.selectedProvider"
        static let claudeModel = "settings.claudeModel"
        static let chatgptModel = "settings.chatgptModel"
        static let notesFolderPath = "settings.notesFolderPath"
        static let summaryAtStopEnabled = "settings.summaryAtStopEnabled"
    }
}
