import Foundation

/// How the app starts the official `claude` command line tool: which file, which environment and which flags.
/// Shared by the conversation provider and the account (sign-in) object so both run the tool the same way.
enum ClaudeCommandLine {
    /// The `claude` file to run. An explicit file wins; otherwise `CLICKY_CLAUDE_BIN` and the usual install folders.
    static func resolveExecutable(explicit explicitURL: URL?, environment: [String: String]) throws -> URL {
        if let explicitURL {
            guard FileManager.default.isExecutableFile(atPath: explicitURL.path) else {
                throw ProviderFailure.cliNotFound
            }
            return explicitURL
        }
        guard let located = ProviderProcessSupport.locateExecutable(
            named: "claude",
            environmentOverrideKey: "CLICKY_CLAUDE_BIN",
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) else {
            throw ProviderFailure.cliNotFound
        }
        return located
    }

    /// The environment the child gets: the shared allowlist from `ProviderProcessSupport` plus the app's own Claude
    /// login folder. Nothing that could switch the tool to an API key, another server, another keychain entry or a
    /// parent Claude Code session is on the list, so nothing needs removing by name.
    static func childEnvironment(base: [String: String], locations: AppDataLocations) -> [String: String] {
        ProviderProcessSupport.scrubbedEnvironment(
            base: base,
            adding: ["CLAUDE_CONFIG_DIR": locations.claudeConfigDirectory.path]
        )
    }

    /// Flags that keep the tool to a plain answer on the subscription: no tools, no settings files, no MCP servers,
    /// no slash commands, nothing saved to disk, and safe mode (measured to cost no extra time).
    /// Never `--bare`, which would drop the subscription login.
    static func isolationArguments(model: String, instructions: String) -> [String] {
        [
            "--model", model,
            "--system-prompt", instructions,
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--safe-mode",
        ]
    }

    /// Arguments for the long-lived conversation process.
    static func conversationArguments(model: String, instructions: String) -> [String] {
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
            + isolationArguments(model: model, instructions: instructions)
    }

    /// Arguments for the one-shot text-only run (the summary). The prompt arrives on standard input.
    static func oneShotArguments(model: String, instructions: String) -> [String] {
        ["-p"] + isolationArguments(model: model, instructions: instructions)
    }

    /// Turns the words of an error answer into the failure the chat can act on.
    /// `assistantErrorKind` is the `error` field the CLI puts on the assistant line (for example `rate_limit`).
    static func classifyFailure(text: String, assistantErrorKind: String?) -> ProviderFailure {
        let lowercasedText = text.lowercased()

        let limitPhrases = ["hit your limit", "usage limit", "limit reached", "out of extra usage"]
        if assistantErrorKind == "rate_limit" || limitPhrases.contains(where: { lowercasedText.contains($0) }) {
            return .usageLimitReached(message: text)
        }

        let signedOutPhrases = ["not logged in", "please run /login", "claude auth login"]
        if assistantErrorKind == "authentication_failed" || signedOutPhrases.contains(where: { lowercasedText.contains($0) }) {
            return .notSignedIn
        }

        return .failed(message: shortPlainMessage(from: text))
    }

    static func shortPlainMessage(from text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty { return "Claude could not answer." }
        if trimmedText.count <= 200 { return trimmedText }
        return String(trimmedText.prefix(200)) + "..."
    }
}
