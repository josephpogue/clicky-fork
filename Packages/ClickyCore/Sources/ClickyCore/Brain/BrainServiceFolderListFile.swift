import Foundation

/// The current search-folder list as the app keeps it, written next to the index so the helper (a separate process
/// that gets its folders once, at launch) learns about a folder removed in Settings during a session.
/// A removal takes effect on the helper's next tool call; an addition only from the next session, because the helper
/// uses the INTERSECTION of its launch folders and this file's list.
public enum BrainServiceFolderListFile {
    public static let fileName = "folders.json"

    /// The list file for an index database: the same folder, `folders.json`.
    public static func url(besideIndexDatabase indexDatabaseURL: URL) -> URL {
        indexDatabaseURL.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }

    /// Atomic write (temp file, then rename), so the helper never reads half a list.
    public static func write(folders: [URL], to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: folders.map(\.path), options: [.sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    /// The folder paths in the file; nil when it is missing, unreadable or not a JSON list of strings.
    public static func read(from fileURL: URL) -> [String]? {
        guard let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return parsed
    }

    /// The launch folders that the file still lists. A missing or corrupt file gives the launch list unchanged; an
    /// empty list in the file gives no folders (every search finds nothing, every read is refused).
    public static func effectiveFolders(launchFolders: [URL], listFileURL: URL) -> [URL] {
        guard let currentPaths = read(from: listFileURL) else { return launchFolders }
        let currentResolvedPaths = Set(currentPaths.map { resolvedPath($0) })
        return launchFolders.filter { currentResolvedPaths.contains(resolvedPath($0.path)) }
    }

    /// Compared by real path, so `/var/x` and `/private/var/x` are the same folder.
    private static func resolvedPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return (path as NSString).standardizingPath
    }
}
