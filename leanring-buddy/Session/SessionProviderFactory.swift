//
//  SessionProviderFactory.swift
//  leanring-buddy
//
//  Creates the AI provider for a session. Both go through the official
//  command line tools on the user's own login, with the app's own sign-in
//  folders from `AppDataLocations`.
//

import ClickyCore
import Foundation

enum SessionProviderFactory {
    static func makeProvider(for providerID: ProviderID, locations: AppDataLocations) -> AnswerProvider {
        switch providerID {
        case .claude:
            // With search folders set, Claude gets the bundled helper as its only tools; nil keeps today's flags.
            return ClaudeCLIProvider(locations: locations, brainToolServer: BrainIndexService.shared.toolServer())
        case .chatgpt:
            return CodexCLIProvider(locations: locations)
        }
    }

    /// The model name to pass for a provider, from the user's settings.
    @MainActor
    static func modelName(for providerID: ProviderID) -> String {
        switch providerID {
        case .claude: return AppSettings.shared.claudeModel
        case .chatgpt: return AppSettings.shared.chatgptModel
        }
    }

    /// The model and effort a "dig deeper" question uses on a provider, from the user's settings.
    @MainActor
    static func digDeeperRequest(for providerID: ProviderID) -> AnswerRequest {
        let settings = AppSettings.shared
        switch providerID {
        case .claude: return AnswerRequest(model: settings.digDeeperClaudeModel, effort: settings.digDeeperEffort)
        case .chatgpt: return AnswerRequest(model: settings.digDeeperChatgptModel, effort: settings.digDeeperEffort)
        }
    }
}
