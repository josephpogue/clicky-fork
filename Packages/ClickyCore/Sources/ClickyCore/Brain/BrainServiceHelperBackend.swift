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
        // Folders the last completed update has not covered: an empty result there is not "no notes", it is "not yet".
        let stillBeingIndexed = BrainServiceFolderListFile.foldersStillBeingIndexed(
            launchFolders: launchFolders, listFileURL: folderListFileURL)
        let notice = stillBeingIndexed.isEmpty ? [] : [Self.stillBeingIndexedNotice(folders: stillBeingIndexed)]
        // The index is opened on each search so an index the app builds after the helper starts still works.
        let index: BrainIndex
        do {
            index = try BrainIndex(databaseURL: indexDatabaseURL, readOnly: true)
        } catch {
            // The first build has not written the database yet.
            if !notice.isEmpty { return notice }
            throw error
        }
        // The index may still hold rows of a removed folder until the next update; the reader is the boundary. The
        // index pages through the ranked rows until `limit` readable hits are found or the rows run out.
        let hits = try index.readableSearch(query: query, wantedCount: max(limit, 1), reader: reader)
        return notice + hits
    }

    public func readFile(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        try currentReader().read(path: path, startLine: startLine, lineCount: lineCount)
    }

    /// A result entry with no file (an empty path) that tells the model the search may be missing notes. The tool
    /// server prints it like a passage, so the model reads it as part of the result.
    static func stillBeingIndexedNotice(folders: [URL]) -> BrainPassage {
        let names = folders.map(\.lastPathComponent).joined(separator: ", ")
        let text = "NOTE: notes in \(names) are still being indexed, so this search may be missing notes from there. "
            + "Do not conclude the notes lack the answer. Say the notes are still being indexed, and use any passages below."
        return BrainPassage(path: "", heading: "Search incomplete", startLine: 0, endLine: 0, text: text, score: 0)
    }
}
