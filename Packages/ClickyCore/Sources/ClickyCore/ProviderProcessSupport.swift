import Foundation

/// Helpers for running the `claude` and `codex` command line tools from a GUI app.
public enum ProviderProcessSupport {
    /// Finds a command line tool. A GUI app does not inherit the shell PATH, so this checks the usual install folders.
    /// The override (for tests and unusual installs) wins when it points at an executable file.
    public static func locateExecutable(
        named executableName: String,
        environmentOverrideKey: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        let fileManager = FileManager.default

        if let overridePath = environment[environmentOverrideKey], !overridePath.isEmpty,
           fileManager.isExecutableFile(atPath: overridePath) {
            return URL(fileURLWithPath: overridePath)
        }

        let searchFolders = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".claude/local").path,
        ]
        for folder in searchFolders {
            let candidatePath = (folder as NSString).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath)
            }
        }
        return nil
    }

    /// The environment a CLI child process gets: no API keys or tokens (the app is subscription only),
    /// and no inherited login folders, plus the app's own variables on top.
    public static func scrubbedEnvironment(
        base: [String: String],
        adding extraVariables: [String: String]
    ) -> [String: String] {
        let namesToRemove: Set<String> = [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
        ]
        var result = base.filter { name, _ in
            !namesToRemove.contains(name) && !name.hasSuffix("_API_KEY")
        }
        for (name, value) in extraVariables {
            result[name] = value
        }
        return result
    }
}
