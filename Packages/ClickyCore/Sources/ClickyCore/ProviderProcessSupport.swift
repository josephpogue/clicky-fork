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

    /// The only variables a CLI child inherits from the app. Everything else is left out, so no key, token, base URL,
    /// keychain-folder switch (such as `CLAUDE_SECURESTORAGE_CONFIG_DIR`) or login folder can reach a child and make
    /// the sign-in act on the user's own Claude Code or Codex login.
    static let inheritedVariableNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING",
    ]

    /// The environment a CLI child process gets: only the variables in `inheritedVariableNames` and the `LC_*`
    /// locale ones from `base`, plus the app's own variables (its `CLAUDE_CONFIG_DIR` or `CODEX_HOME`) on top.
    public static func scrubbedEnvironment(
        base: [String: String],
        adding extraVariables: [String: String]
    ) -> [String: String] {
        var result = base.filter { name, _ in
            inheritedVariableNames.contains(name) || name.hasPrefix("LC_")
        }
        for (name, value) in extraVariables {
            result[name] = value
        }
        return result
    }
}
