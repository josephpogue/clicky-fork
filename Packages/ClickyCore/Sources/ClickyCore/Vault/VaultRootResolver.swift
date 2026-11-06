import Foundation

/// Finds the user's notes folder. No path is built into the app: the environment override wins,
/// then the Settings value, else nil (the caller then tells the user to choose a notes folder).
public enum VaultRootResolver {
    public static let rootEnvironmentKey = "CLICKY_VAULT_ROOT"
    public static let dryRunEnvironmentKey = "CLICKY_VAULT_DRY_RUN"

    public static func resolve(notesFolderSetting: String?, environment: [String: String]) -> URL? {
        for candidate in [environment[rootEnvironmentKey], notesFolderSetting] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            let expanded = NSString(string: raw).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return nil
    }

    public static func isDryRun(environment: [String: String]) -> Bool {
        environment[dryRunEnvironmentKey] == "1"
    }
}
