import Foundation

/// The one writer of `folders.json`. Every write runs inside this type's lock and reads the CURRENT folder list and
/// covered-folders list there, never a caller's earlier snapshot. So a late write from an index run (which started
/// from [A, B]) lands after Settings removed B and still writes [A]; the last write to run is always the newest list.
/// `indexedFolders` is cut to the folders that are in `folders`, so the file never claims coverage of a folder it does
/// not list.
public final class BrainServiceFolderListWriter: @unchecked Sendable {
    private let listFileURL: URL
    private let indexDatabaseURL: URL
    private let currentFolders: @Sendable () -> [URL]
    private let coveredFolders: @Sendable () -> [URL]?
    private let log: @Sendable (String) -> Void

    /// Serializes the read-then-write; also guards `lastWriteSucceeded`. Never held while calling back into the owner
    /// for anything but the two quick state readers.
    private let writeLock = NSLock()
    private var lastWriteSucceeded = true

    /// - currentFolders: the folders Settings lists right now (expanded), read inside the lock on every write.
    /// - coveredFolders: the folders the last COMPLETED update covered; nil when this launch has not finished one yet,
    ///   in which case the file's own coverage is read back (only when an index database exists).
    public init(
        listFileURL: URL, indexDatabaseURL: URL,
        currentFolders: @escaping @Sendable () -> [URL], coveredFolders: @escaping @Sendable () -> [URL]?,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.listFileURL = listFileURL
        self.indexDatabaseURL = indexDatabaseURL
        self.currentFolders = currentFolders
        self.coveredFolders = coveredFolders
        self.log = log
    }

    /// False after the last write failed twice and the stale file could not be trusted: the owner stops attaching
    /// passages until a write succeeds, because the helper can no longer follow the list.
    public var fileIsCurrent: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return lastWriteSucceeded
    }

    /// Writes the newest list. With no folders and no index folder yet, nothing is created.
    public func writeNewest() {
        writeLock.lock()
        defer { writeLock.unlock() }
        let folders = currentFolders()
        if folders.isEmpty,
           !FileManager.default.fileExists(atPath: indexDatabaseURL.deletingLastPathComponent().path) { return }
        let listedPaths = Set(folders.map(\.path))
        let covered = coveredFoldersLocked().filter { listedPaths.contains($0.path) }
        lastWriteSucceeded = BrainServiceFolderListFile.writeRetryingOnce(
            folders: folders, indexedFolders: covered, to: listFileURL, log: log)
    }

    /// What the last completed update covered; before the first of this launch it is read back from the file (a bare
    /// list from the first wave counts as covered, as that service indexed what it listed), and with no index database
    /// on disk nothing is covered.
    private func coveredFoldersLocked() -> [URL] {
        if let covered = coveredFolders() { return covered }
        guard FileManager.default.fileExists(atPath: indexDatabaseURL.path),
              let listing = BrainServiceFolderListFile.readListing(from: listFileURL) else { return [] }
        return (listing.indexedFolders ?? listing.folders).map { URL(fileURLWithPath: $0) }
    }
}
