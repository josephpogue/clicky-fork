import Foundation

/// The plain words the chat shows for each way asking a provider can fail.
public enum ProviderFailureNotice {
    public static func displayName(for provider: ProviderID) -> String {
        switch provider {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    public static func text(for failure: ProviderFailure, provider: ProviderID) -> String {
        let name = displayName(for: provider)
        switch failure {
        case .notSignedIn:
            return "Sign in to \(name) in Settings"
        case .cliNotFound:
            return provider == .claude ? "Install Claude Code" : "Install Codex"
        case .notSubscriptionLogin:
            return "This app only uses a \(name) subscription login"
        case .usageLimitReached(let message):
            return message
        case .failed(let message):
            return message
        }
    }
}
