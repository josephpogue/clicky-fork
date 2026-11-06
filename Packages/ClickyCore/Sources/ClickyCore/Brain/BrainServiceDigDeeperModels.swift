import Foundation

/// The model lists "dig deeper" offers in Settings.
public enum BrainServiceDigDeeperModels {
    /// The Claude aliases when the provider row has no list yet (before sign-in).
    private static let claudeAliases = ["sonnet", "opus", "haiku"]

    /// The Claude provider row's list, with `opus` present even before sign-in.
    public static func claude(providerRowModels: [String]) -> [String] {
        var models = providerRowModels.isEmpty ? claudeAliases : providerRowModels
        if !models.contains("opus") { models.append("opus") }
        return models
    }

    /// The CLI's own default (an empty string), then the ChatGPT row's models.
    public static func chatgpt(providerRowModels: [String]) -> [String] {
        [""] + providerRowModels.filter { !$0.isEmpty }
    }
}
