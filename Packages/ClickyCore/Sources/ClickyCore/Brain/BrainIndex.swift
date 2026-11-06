import Foundation

/// What one index update did.
public struct BrainIndexUpdateSummary: Sendable, Equatable {
    public var filesIndexed: Int
    public var filesUnchanged: Int
    public var filesRemoved: Int
    public var chunkCount: Int
    public var seconds: Double

    public init(filesIndexed: Int, filesUnchanged: Int, filesRemoved: Int, chunkCount: Int, seconds: Double) {
        self.filesIndexed = filesIndexed
        self.filesUnchanged = filesUnchanged
        self.filesRemoved = filesRemoved
        self.chunkCount = chunkCount
        self.seconds = seconds
    }
}

/// The SQLite FTS5 (BM25) index over the text files in the search folders, chunked by markdown heading.
/// Owned by the brain-index slice. Foundation stub: holds nothing and finds nothing.
public final class BrainIndex: @unchecked Sendable {
    public let databaseURL: URL

    /// `readOnly` is for the helper, which only searches while the app keeps the index up to date.
    public init(databaseURL: URL, readOnly: Bool = false) throws {
        self.databaseURL = databaseURL
    }

    /// Brings the index up to date with the search folders by file modification time, and drops files that are gone
    /// or no longer under any search folder.
    @discardableResult
    public func update(searchFolders: [URL]) throws -> BrainIndexUpdateSummary {
        BrainIndexUpdateSummary(filesIndexed: 0, filesUnchanged: 0, filesRemoved: 0, chunkCount: 0, seconds: 0)
    }

    /// The search behind `search_brain`: best passages first, at most `limit`.
    public func search(query: String, limit: Int) throws -> [BrainPassage] {
        []
    }

    /// The passages sent with a question: only those above the score floor, within the passage and size budget,
    /// boosted toward the project the front window names (`projectNames` adds the notes folder's project pages to
    /// the git repo folder names found while indexing). Empty when nothing clears the floor.
    public func passages(
        forQuestion question: String, frontAppName: String?, frontWindowTitle: String?, projectNames: [String]
    ) throws -> [BrainPassage] {
        []
    }

    /// Absolute paths of indexed files with exactly this file name (the routing list is found as `registry.md`).
    public func indexedFiles(named fileName: String) throws -> [String] {
        []
    }

    /// Folder names of the git repos found while indexing.
    public func repositoryProjectNames() throws -> [String] {
        []
    }
}
