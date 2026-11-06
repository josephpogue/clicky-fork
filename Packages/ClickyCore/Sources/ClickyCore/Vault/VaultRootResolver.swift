import Foundation

/// Finds the user's notes folder. No path is built into the app: the environment override wins,
/// then the Settings value, else nil (the caller then tells the user to choose a notes folder).
public enum VaultRootResolver {
    public static let rootEnvironmentKey = "CLICKY_VAULT_ROOT"
    public static let dryRunEnvironmentKey = "CLICKY_VAULT_DRY_RUN"

    /// `homeDirectory` is what a leading `~` stands for; nil means the signed-in user's home folder.
    /// Tests pass a temp folder so no real home folder is read.
    public static func resolve(
        notesFolderSetting: String?, environment: [String: String], homeDirectory: URL? = nil
    ) -> URL? {
        for candidate in [environment[rootEnvironmentKey], notesFolderSetting] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            let expanded = expandTilde(raw, homeDirectory: homeDirectory)
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return nil
    }

    private static func expandTilde(_ path: String, homeDirectory: URL?) -> String {
        guard let homeDirectory else { return NSString(string: path).expandingTildeInPath }
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path }
        return NSString(string: path).expandingTildeInPath
    }

    public static func isDryRun(environment: [String: String]) -> Bool {
        environment[dryRunEnvironmentKey] == "1"
    }
}
