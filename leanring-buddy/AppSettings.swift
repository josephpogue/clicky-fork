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

    /// How answers reach the user: text beside the cursor, spoken, or both. Text by default.
    @Published var answerDeliveryMode: AnswerDeliveryMode {
        didSet { userDefaults.set(answerDeliveryMode.rawValue, forKey: Keys.answerDeliveryMode) }
    }

    /// The macOS voice (an `AVSpeechSynthesisVoice` identifier) that reads spoken answers. Nil means the
    /// system's default voice for the user's language.
    @Published var spokenAnswerVoiceIdentifier: String? {
        didSet { userDefaults.set(spokenAnswerVoiceIdentifier, forKey: Keys.spokenAnswerVoiceIdentifier) }
    }

    /// Folders whose notes Clicky may search for a question (absolute paths). Empty means the brain feature is off and
    /// Clicky behaves exactly as without it.
    @Published var brainSearchFolderPaths: [String] {
        didSet { userDefaults.set(brainSearchFolderPaths, forKey: Keys.brainSearchFolderPaths) }
    }

    /// The stronger Claude model a "dig deeper" question uses, for that one question.
    @Published var digDeeperClaudeModel: String {
        didSet { userDefaults.set(digDeeperClaudeModel, forKey: Keys.digDeeperClaudeModel) }
    }

    /// The stronger ChatGPT model a "dig deeper" question uses. Empty means the CLI's own default model.
    @Published var digDeeperChatgptModel: String {
        didSet { userDefaults.set(digDeeperChatgptModel, forKey: Keys.digDeeperChatgptModel) }
    }

    /// How hard the model thinks on a "dig deeper" question. High by default.
    @Published var digDeeperEffort: AnswerEffort {
        didSet { userDefaults.set(digDeeperEffort.rawValue, forKey: Keys.digDeeperEffort) }
    }

    /// Seconds the last answer took, per provider raw value, shown in Settings.
    @Published private(set) var measuredAnswerSeconds: [String: Double] {
        didSet { userDefaults.set(measuredAnswerSeconds, forKey: Keys.measuredAnswerSeconds) }
    }

    func recordMeasuredAnswerSeconds(_ seconds: Double, for provider: ProviderID) {
        measuredAnswerSeconds[provider.rawValue] = seconds
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        selectedProvider = userDefaults.string(forKey: Keys.selectedProvider).flatMap(ProviderID.init(rawValue:)) ?? .claude
        claudeModel = userDefaults.string(forKey: Keys.claudeModel) ?? "sonnet"
        chatgptModel = userDefaults.string(forKey: Keys.chatgptModel) ?? ""
        notesFolderPath = userDefaults.string(forKey: Keys.notesFolderPath)
        summaryAtStopEnabled = userDefaults.object(forKey: Keys.summaryAtStopEnabled) as? Bool ?? true
        answerDeliveryMode = userDefaults.string(forKey: Keys.answerDeliveryMode).flatMap(AnswerDeliveryMode.init(rawValue:)) ?? .text
        spokenAnswerVoiceIdentifier = userDefaults.string(forKey: Keys.spokenAnswerVoiceIdentifier)
        brainSearchFolderPaths = userDefaults.stringArray(forKey: Keys.brainSearchFolderPaths) ?? []
        digDeeperClaudeModel = userDefaults.string(forKey: Keys.digDeeperClaudeModel) ?? "opus"
        digDeeperChatgptModel = userDefaults.string(forKey: Keys.digDeeperChatgptModel) ?? ""
        digDeeperEffort = userDefaults.string(forKey: Keys.digDeeperEffort).flatMap(AnswerEffort.init(rawValue:)) ?? .high
        measuredAnswerSeconds = userDefaults.dictionary(forKey: Keys.measuredAnswerSeconds) as? [String: Double] ?? [:]
    }

    private enum Keys {
        static let selectedProvider = "settings.selectedProvider"
        static let claudeModel = "settings.claudeModel"
        static let chatgptModel = "settings.chatgptModel"
        static let notesFolderPath = "settings.notesFolderPath"
        static let summaryAtStopEnabled = "settings.summaryAtStopEnabled"
        static let measuredAnswerSeconds = "settings.measuredAnswerSeconds"
        static let answerDeliveryMode = "settings.answerDeliveryMode"
        static let spokenAnswerVoiceIdentifier = "settings.spokenAnswerVoiceIdentifier"
        static let brainSearchFolderPaths = "settings.brainSearchFolderPaths"
        static let digDeeperClaudeModel = "settings.digDeeperClaudeModel"
        static let digDeeperChatgptModel = "settings.digDeeperChatgptModel"
        static let digDeeperEffort = "settings.digDeeperEffort"
    }
}
