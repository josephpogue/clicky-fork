import Foundation

/// Which files the brain index holds and which no tool may ever read. Owned by the brain-files slice.
/// The index (brain-index slice) and the reader (brain-files slice) both ask these rules, so a file is never readable
/// by one path and searchable by another.
public enum BrainFileRules {
    /// Files larger than this are never indexed (they stay readable by path).
    public static let maximumIndexedFileBytes = 512 * 1024

    /// The file kinds the index holds.
    public static let indexedFileExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Folder names whose contents no tool may read: git internals, installed packages, and the folders where
    /// command line tools keep keys and logins.
    static let neverReadableFolderNames: Set<String> = [
        ".git", "node_modules", ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".azure", ".gcloud",
    ]

    /// File names that hold logins on their own, whatever their extension.
    static let neverReadableExactFileNames: Set<String> = [
        ".netrc", ".npmrc", ".pgpass", ".pypirc", ".git-credentials", ".htpasswd",
        // Tool logins and editor/agent configs that carry tokens
        ".mcp.json", "auth.json", "hosts.yml", "hosts.yaml", ".dev.vars",
    ]

    /// Extensions of key, certificate store, keychain and password vault files.
    static let neverReadableExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "jks", "keystore", "p8", "ppk", "der", "gpg", "kdbx", "keychain", "keychain-db",
        // Terraform variable and state files hold provider keys and passwords in the clear
        "tfvars", "tfstate",
    ]

    /// Words that mark a file as holding a secret when they appear anywhere in its name (`*token*`, `credentials*`,
    /// `secrets*` in the design, widened to any position so `prod-credentials.json` is caught too).
    static let neverReadableNameWords: [String] = ["credential", "secret", "token"]

    /// Folder names the index walker never enters. Their files stay readable by path, except the never-readable ones.
    static let skippedIndexFolderNames: Set<String> = [
        "build", "dist", "out", ".next", "deriveddata", ".build", "pods", "venv", ".venv", "__pycache__", "target",
        ".cache", ".turbo", "coverage",
    ]

    /// True for a file no tool may read and the index never holds: secrets, git internals, node_modules, key folders.
    /// Callers check both the path as given and the path after resolving symlinks.
    public static func isNeverReadable(path: String) -> Bool {
        let pathComponents = path.split(separator: "/").map { String($0).lowercased() }
        guard let fileName = pathComponents.last else { return false }
        for componentIndex in 0..<pathComponents.count {
            let component = pathComponents[componentIndex]
            if neverReadableFolderNames.contains(component) { return true }
            // Every name that starts with `.env`: `.env`, `.env.local`, `.envrc`, `.env-local`, `.env_prod`, and a
            // folder of that name (a Python environment). `environment.md` and `envoy.md` do not start with a dot.
            if component.hasPrefix(".env") { return true }
        }
        return isNeverReadableFileName(fileName)
    }

    /// The name-only half of `isNeverReadable`, for one lowercased file name.
    static func isNeverReadableFileName(_ lowercasedFileName: String) -> Bool {
        if neverReadableExactFileNames.contains(lowercasedFileName) { return true }
        // `prod.env`, `staging.env`
        if lowercasedFileName.hasSuffix(".env") { return true }
        // `terraform.tfstate.backup`, `terraform.tfstate.1700000000.backup`
        if lowercasedFileName.contains(".tfstate.") { return true }
        let fileExtension = (lowercasedFileName as NSString).pathExtension
        if neverReadableExtensions.contains(fileExtension) { return true }
        // SSH keys: `id_rsa`, `id_ed25519`, `id_ecdsa.pub`
        if lowercasedFileName.hasPrefix("id_") && (fileExtension.isEmpty || fileExtension == "pub") { return true }
        for word in neverReadableNameWords where lowercasedFileName.contains(word) {
            return true
        }
        return false
    }

    /// True for a directory the index walker skips without descending: hidden folders, worktree copies (`*-worktrees`),
    /// production copies (`*-prod`), build output, and every never-readable folder.
    public static func isSkippedDirectoryForIndex(name: String) -> Bool {
        let lowercasedName = name.lowercased()
        if lowercasedName.hasPrefix(".") { return true }
        if lowercasedName.hasSuffix("-worktrees") || lowercasedName.hasSuffix("-prod") { return true }
        if skippedIndexFolderNames.contains(lowercasedName) { return true }
        return neverReadableFolderNames.contains(lowercasedName)
    }

    /// True for a file the index holds: markdown or plain text, not never-readable, at most the size cap.
    public static func isIndexableFile(path: String, byteCount: Int) -> Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard indexedFileExtensions.contains(fileExtension) else { return false }
        guard byteCount <= maximumIndexedFileBytes else { return false }
        return !isNeverReadable(path: path)
    }
}
