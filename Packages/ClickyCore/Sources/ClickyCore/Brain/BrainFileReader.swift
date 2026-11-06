import Foundation

/// Reads lines of one text file for `read_brain_file`, only inside the search folders. Owned by the brain-files slice.
/// Foundation stub: refuses every path.
public struct BrainFileReader: Sendable {
    public static let maximumLinesPerCall = 200
    public static let maximumCharactersPerCall = 16_000

    public let searchFolders: [URL]

    public init(searchFolders: [URL]) {
        self.searchFolders = searchFolders
    }

    /// The file a path names, after resolving symlinks, when it may be read. Throws `BrainFileRefusal` otherwise.
    public func resolveReadableFile(_ path: String) throws -> URL {
        throw BrainFileRefusal.outsideSearchFolders
    }

    /// `lineCount` lines from `startLine` (1-based), capped by `maximumLinesPerCall` and `maximumCharactersPerCall`.
    public func read(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        throw BrainFileRefusal.outsideSearchFolders
    }
}
