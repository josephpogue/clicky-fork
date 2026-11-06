import Foundation

/// The real tools behind the helper's MCP server. Lives here, not in the helper's `main.swift`, so tests drive it.
/// The folders are re-resolved on every call: the app rewrites `folders.json` when Settings changes the list, and a
/// folder removed there stops being searchable and readable at once.
public struct BrainServiceHelperBackend: BrainToolBackend {
    public let indexDatabaseURL: URL
    public let launchFolders: [URL]
    public let folderListFileURL: URL

    public init(indexDatabaseURL: URL, launchFolders: [URL], folderListFileURL: URL) {
        self.indexDatabaseURL = indexDatabaseURL
        self.launchFolders = launchFolders
        self.folderListFileURL = folderListFileURL
    }

    private func currentReader() -> BrainFileReader {
        BrainFileReader(
            searchFolders: BrainServiceFolderListFile.effectiveFolders(
                launchFolders: launchFolders, listFileURL: folderListFileURL))
    }

    public func search(query: String, limit: Int) throws -> [BrainPassage] {
        let reader = currentReader()
        // No folders left: nothing is searchable, and the index is not even opened.
        if reader.searchFolders.isEmpty { return [] }
        // The index is opened on each search so an index the app builds after the helper starts still works.
        let index = try BrainIndex(databaseURL: indexDatabaseURL, readOnly: true)
        // The index may still hold rows of a removed folder until the next update; the reader is the boundary.
        return try index.search(query: query, limit: limit).filter { (try? reader.resolveReadableFile($0.path)) != nil }
    }

    public func readFile(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        try currentReader().read(path: path, startLine: startLine, lineCount: lineCount)
    }
}
