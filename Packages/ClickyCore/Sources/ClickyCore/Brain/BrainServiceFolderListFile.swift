import Foundation

/// The current search-folder list as the app keeps it, written next to the index so the helper (a separate process
/// that gets its folders once, at launch) learns about a folder removed in Settings during a session.
/// A removal takes effect on the helper's next tool call; an addition only from the next session, because the helper
/// uses the INTERSECTION of its launch folders and this file's list.
///
/// The file also says which folders the last COMPLETED index update covered (`indexedFolders`), so the helper can tell
/// "no note matched" from "that folder is not indexed yet". Two shapes are read: the current object
/// `{"folders": [...], "indexedFolders": [...]}` and the bare list `[...]` the first wave wrote (no coverage claim).
public enum BrainServiceFolderListFile {
    public static let fileName = "folders.json"

    /// What the file holds. `indexedFolders` is nil for a file that has no such field.
    public struct Listing: Equatable, Sendable {
        public var folders: [String]
        public var indexedFolders: [String]?
    }

    /// The list file for an index database: the same folder, `folders.json`.
    public static func url(besideIndexDatabase indexDatabaseURL: URL) -> URL {
        indexDatabaseURL.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }

    /// Atomic write (temp file, then rename), so the helper never reads half a list. `indexedFolders` nil writes the
    /// bare list (no coverage claim); a list, even an empty one, writes the object with the coverage.
    public static func write(folders: [URL], indexedFolders: [URL]? = nil, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let folderPaths = folders.map(\.path)
        let payload: Any
        if let indexedFolders {
            payload = ["folders": folderPaths, "indexedFolders": indexedFolders.map(\.path)]
        } else {
            payload = folderPaths
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    /// Writes, and on a failure tries once more. When it still fails it logs, tries to remove the stale file (so the
    /// helper falls back to its launch list rather than a list the app can no longer keep current) and returns false;
    /// the caller then stops attaching passages until a write succeeds.
    public static func writeRetryingOnce(
        write: () throws -> Void, removeStaleFile: () throws -> Void, log: (String) -> Void
    ) -> Bool {
        var lastProblem: Error?
        for _ in 0..<2 {
            do {
                try write()
                return true
            } catch {
                lastProblem = error
            }
        }
        log("Brain folder list file: write failed twice (\(lastProblem.map { "\($0)" } ?? "unknown")).")
        do {
            try removeStaleFile()
        } catch {
            log("Brain folder list file: the stale file could not be removed (\(error)).")
        }
        return false
    }

    /// The same with the real write and the real removal of `fileURL`.
    public static func writeRetryingOnce(
        folders: [URL], indexedFolders: [URL]?, to fileURL: URL, log: (String) -> Void
    ) -> Bool {
        writeRetryingOnce(
            write: { try write(folders: folders, indexedFolders: indexedFolders, to: fileURL) },
            removeStaleFile: {
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
                try FileManager.default.removeItem(at: fileURL)
            },
            log: log)
    }

    /// The file's content; nil when it is missing, unreadable or in neither shape.
    public static func readListing(from fileURL: URL) -> Listing? {
        guard let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let barePaths = parsed as? [String] { return Listing(folders: barePaths, indexedFolders: nil) }
        guard let object = parsed as? [String: Any], let folderPaths = object["folders"] as? [String] else { return nil }
        if let rawIndexed = object["indexedFolders"] {
            // A field of the wrong type is a corrupt file, not a missing field.
            guard let indexedPaths = rawIndexed as? [String] else { return nil }
            return Listing(folders: folderPaths, indexedFolders: indexedPaths)
        }
        return Listing(folders: folderPaths, indexedFolders: nil)
    }

    /// The folder paths in the file; nil when it is missing, unreadable or not a valid list file.
    public static func read(from fileURL: URL) -> [String]? {
        readListing(from: fileURL)?.folders
    }

    /// The launch folders that the file still lists. A missing or corrupt file gives the launch list unchanged; an
    /// empty list in the file gives no folders (every search finds nothing, every read is refused).
    public static func effectiveFolders(launchFolders: [URL], listFileURL: URL) -> [URL] {
        guard let currentPaths = read(from: listFileURL) else { return launchFolders }
        return foldersInBoth(startList: launchFolders, currentList: currentPaths.map { URL(fileURLWithPath: $0) })
    }

    /// The folders of `startList` that `currentList` still has, compared by real path: what a session may search and
    /// read. A folder added to the current list after the session started is not in it.
    public static func foldersInBoth(startList: [URL], currentList: [URL]) -> [URL] {
        let currentResolvedPaths = Set(currentList.map { resolvedPath($0.path) })
        return startList.filter { currentResolvedPaths.contains(resolvedPath($0.path)) }
    }

    /// The folders this session serves that the last completed update did not cover yet. Empty when the file is
    /// missing, corrupt or from before the field existed: nothing is known, so nothing is claimed.
    public static func foldersStillBeingIndexed(launchFolders: [URL], listFileURL: URL) -> [URL] {
        guard let listing = readListing(from: listFileURL), let indexedPaths = listing.indexedFolders else { return [] }
        let indexedResolvedPaths = Set(indexedPaths.map { resolvedPath($0) })
        let served = foldersInBoth(startList: launchFolders, currentList: listing.folders.map { URL(fileURLWithPath: $0) })
        return served.filter { !indexedResolvedPaths.contains(resolvedPath($0.path)) }
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
