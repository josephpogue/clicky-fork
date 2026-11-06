import Foundation

/// Where the app keeps its own files. Everything sits under one root so the app never touches
/// the user's own Claude Code, Codex or notes folders.
public struct AppDataLocations: Equatable, Sendable {
    /// `$CLICKY_DATA_DIR` when set, else `~/Library/Application Support/Clicky Fork`.
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Used as `CLAUDE_CONFIG_DIR`, so the app's Claude login is separate from the user's own.
    public var claudeConfigDirectory: URL {
        root.appendingPathComponent("providers/claude-config", isDirectory: true)
    }

    /// Used as `CODEX_HOME`, so the app's ChatGPT login is separate from the user's own.
    public var codexHomeDirectory: URL {
        root.appendingPathComponent("providers/codex-home", isDirectory: true)
    }

    /// An empty folder the CLIs run in, so they find no project files to read.
    public var providerWorkingDirectory: URL {
        root.appendingPathComponent("providers/workdir", isDirectory: true)
    }

    /// The brain search index (SQLite FTS5), rebuilt from the search folders; never inside them.
    public var brainIndexDirectory: URL {
        root.appendingPathComponent("brain-index", isDirectory: true)
    }

    public var brainIndexDatabaseURL: URL {
        brainIndexDirectory.appendingPathComponent("index.sqlite", isDirectory: false)
    }

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppDataLocations {
        if let overridePath = environment["CLICKY_DATA_DIR"], !overridePath.isEmpty {
            return AppDataLocations(root: URL(fileURLWithPath: overridePath, isDirectory: true))
        }
        let applicationSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppDataLocations(
            root: applicationSupportDirectory.appendingPathComponent("Clicky Fork", isDirectory: true)
        )
    }

    public func createDirectories() throws {
        for directory in [sessionsDirectory, claudeConfigDirectory, codexHomeDirectory, providerWorkingDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
