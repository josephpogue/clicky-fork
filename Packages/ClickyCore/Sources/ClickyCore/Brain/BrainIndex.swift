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
/// Titles weigh 10 times a body word and headings 5 times, so a note about "build" beats a note that mentions it.
public final class BrainIndex: @unchecked Sendable {
    public let databaseURL: URL

    /// Bump when the table layout or the chunking changes: an index with another version is rebuilt.
    static let schemaVersion = 1

    /// bm25 column weights: path 0 (unindexed), title 10, heading 5, body 1.
    static let rankExpression = "bm25(chunks, 0, 10.0, 5.0, 1.0)"

    /// An override of the score floor, for tests. Nil (the default) means the curve `scoreFloor(forChunkCount:)`.
    public nonisolated(unsafe) static var passageScoreFloor: Double? = nil
    /// The floor never goes below this. A tiny corpus (the test Mac's five-chunk fixture brain) gives every word a
    /// low rarity: its port note scores 2.7 and its release note 2.6 for their questions, while a question that
    /// matches no word scores nothing, so 2.0 keeps those attached. From about 7 chunks the curve is above it.
    public nonisolated(unsafe) static var minimumScoreFloor: Double = 2.0
    /// The floor curve `a + b * ln(N)` for `N` chunks. BM25 scores grow with corpus size (idf), so one fixed floor
    /// cannot fit a small and a large corpus. Fitted to the bench on the real notes (2026-11-06): about 14 at 27,527
    /// chunks (all of `~/brain`) and about 11.5 at 4,680 (`~/brain/wiki`).
    public static let scoreFloorIntercept = -0.4
    public static let scoreFloorSlope = 1.41

    /// The override when set, else the curve.
    static func effectiveScoreFloor(override: Double?, chunkCount: Int) -> Double {
        override ?? scoreFloor(forChunkCount: chunkCount)
    }

    /// The score a passage must reach (after the project boost) for an index of `chunkCount` chunks.
    public static func scoreFloor(forChunkCount chunkCount: Int) -> Double {
        guard chunkCount > 1 else { return minimumScoreFloor }
        return max(minimumScoreFloor, scoreFloorIntercept + scoreFloorSlope * log(Double(chunkCount)))
    }
    /// A passage below this share of the best passage's score is dropped.
    public nonisolated(unsafe) static var relativeScoreFloor: Double = 0.35
    /// Multiplier for a passage inside the project the front window names.
    public nonisolated(unsafe) static var projectBoostFactor: Double = 1.5
    public nonisolated(unsafe) static var maximumPassages = 4
    public nonisolated(unsafe) static var maximumPassagesPerFile = 2
    /// About 1,500 tokens.
    public nonisolated(unsafe) static var maximumPassageCharacters = 6_000
    /// Under this many characters of room left, a passage is skipped instead of cut.
    static let minimumUsefulCutCharacters = 200
    static let candidateCount = 20

    /// The connection updates write through (in a read-only index, the one connection there is).
    private let database: SQLiteDatabase
    /// The connection every read goes through. WAL lets it read the last committed index while `update` is mid-build,
    /// so a question never waits for a build.
    private let readDatabase: SQLiteDatabase
    private let readOnly: Bool
    /// One update at a time.
    private let writeLock = NSLock()
    /// One read at a time on the read connection (a prepared statement is not shared between threads).
    private let readLock = NSLock()

    /// `readOnly` is for the helper, which only searches while the app keeps the index up to date.
    public init(databaseURL: URL, readOnly: Bool = false) throws {
        self.databaseURL = databaseURL
        self.readOnly = readOnly
        if readOnly {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw BrainIndexError.databaseMissing(path: databaseURL.path)
            }
            database = try SQLiteDatabase(url: databaseURL, readOnly: true)
            readDatabase = database
        } else {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writeDatabase = try SQLiteDatabase(url: databaseURL, readOnly: false)
            // WAL lets the helper and our own read connection read while the app updates.
            try writeDatabase.execute("PRAGMA journal_mode = WAL")
            try writeDatabase.execute("PRAGMA synchronous = NORMAL")
            try Self.createSchemaIfNeeded(in: writeDatabase)
            database = writeDatabase
            readDatabase = try SQLiteDatabase(url: databaseURL, readOnly: true)
        }
    }

    private static func createSchemaIfNeeded(in database: SQLiteDatabase) throws {
        try database.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        var storedVersion: String?
        try database.prepare("SELECT value FROM meta WHERE key = 'schema_version'").rows { row in
            storedVersion = row.text(at: 0)
        }
        if let storedVersion, storedVersion != String(Self.schemaVersion) {
            try database.execute("DROP TABLE IF EXISTS chunks; DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS repositories")
        }
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL, repository_root TEXT,
                first_rowid INTEGER, last_rowid INTEGER, chunk_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS repositories (path TEXT PRIMARY KEY, name TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
                path UNINDEXED, title, heading, body, start_line UNINDEXED, end_line UNINDEXED,
                tokenize = 'porter unicode61'
            );
            """)
        try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)")
            .run([.text(String(Self.schemaVersion))])
    }

    // MARK: Update

    private struct FoundFile {
        var path: String
        var modificationTime: Double
        var size: Int
        var repositoryRoot: String?
    }

    /// Brings the index up to date with the search folders by file modification time, and drops files that are gone
    /// or no longer under any search folder.
    @discardableResult
    public func update(searchFolders: [URL]) throws -> BrainIndexUpdateSummary {
        writeLock.lock()
        defer { writeLock.unlock() }
        let startedAt = Date()
        // Every stored path is a resolved path, so the folders are resolved too (`/var` is `/private/var`).
        let resolvedFolders = searchFolders.map { Self.fullyResolved($0) }
        var foundFiles: [FoundFile] = []
        var repositoryRoots: [String] = []
        var visitedPaths = Set<String>()
        for folder in resolvedFolders {
            walk(
                directory: folder, repositoryRoot: nil, resolvedFolders: resolvedFolders, visitedPaths: &visitedPaths,
                foundFiles: &foundFiles, repositoryRoots: &repositoryRoots)
        }

        var storedFiles: [String: (modificationTime: Double, size: Int, firstRowID: Int64?, lastRowID: Int64?, chunkCount: Int)] = [:]
        try database.prepare("SELECT path, mtime, size, first_rowid, last_rowid, chunk_count FROM files").rows { row in
            storedFiles[row.text(at: 0) ?? ""] = (
                row.real(at: 1), Int(row.integer(at: 2)), row.isNull(at: 3) ? nil : row.integer(at: 3),
                row.isNull(at: 4) ? nil : row.integer(at: 4), Int(row.integer(at: 5))
            )
        }

        var summary = BrainIndexUpdateSummary(filesIndexed: 0, filesUnchanged: 0, filesRemoved: 0, chunkCount: 0, seconds: 0)
        try database.execute("BEGIN IMMEDIATE")
        do {
            let deleteChunks = try database.prepare("DELETE FROM chunks WHERE rowid BETWEEN ? AND ?")
            let deleteFile = try database.prepare("DELETE FROM files WHERE path = ?")
            let insertChunk = try database.prepare(
                "INSERT INTO chunks (path, title, heading, body, start_line, end_line) VALUES (?, ?, ?, ?, ?, ?)")
            let insertFile = try database.prepare(
                "INSERT OR REPLACE INTO files (path, mtime, size, repository_root, first_rowid, last_rowid, chunk_count) VALUES (?, ?, ?, ?, ?, ?, ?)")

            let foundPaths = Set(foundFiles.map(\.path))
            for (storedPath, stored) in storedFiles where !foundPaths.contains(storedPath) {
                if let first = stored.firstRowID, let last = stored.lastRowID {
                    try deleteChunks.run([.integer(first), .integer(last)])
                }
                try deleteFile.run([.text(storedPath)])
                summary.filesRemoved += 1
            }

            var totalChunkCount = 0
            for foundFile in foundFiles {
                if let stored = storedFiles[foundFile.path], stored.modificationTime == foundFile.modificationTime,
                    stored.size == foundFile.size
                {
                    summary.filesUnchanged += 1
                    totalChunkCount += stored.chunkCount
                    // The repository root can change without the file changing (a .git folder added later)
                    try database.prepare("UPDATE files SET repository_root = ? WHERE path = ?")
                        .run([foundFile.repositoryRoot.map { .text($0) } ?? .null, .text(foundFile.path)])
                    continue
                }
                if let stored = storedFiles[foundFile.path], let first = stored.firstRowID, let last = stored.lastRowID {
                    try deleteChunks.run([.integer(first), .integer(last)])
                }
                guard let data = Self.readIndexableFile(atPath: foundFile.path) else {
                    // Unreadable now, or no longer a plain file: leave it out; the next update tries again.
                    try deleteFile.run([.text(foundFile.path)])
                    continue
                }
                let fileName = (foundFile.path as NSString).lastPathComponent
                let isMarkdown = ["md", "markdown"].contains((fileName as NSString).pathExtension.lowercased())
                let chunks = MarkdownChunker.chunks(
                    text: String(decoding: data, as: UTF8.self), fileName: fileName, isMarkdown: isMarkdown)
                var firstRowID: Int64?
                var lastRowID: Int64?
                for chunk in chunks {
                    try insertChunk.run([
                        .text(foundFile.path), .text(chunk.title), chunk.heading.map { .text($0) } ?? .null,
                        .text(chunk.body), .integer(Int64(chunk.startLine)), .integer(Int64(chunk.endLine)),
                    ])
                    let rowID = database.lastInsertedRowID
                    if firstRowID == nil { firstRowID = rowID }
                    lastRowID = rowID
                }
                try insertFile.run([
                    .text(foundFile.path), .real(foundFile.modificationTime), .integer(Int64(foundFile.size)),
                    foundFile.repositoryRoot.map { .text($0) } ?? .null,
                    firstRowID.map { .integer($0) } ?? .null, lastRowID.map { .integer($0) } ?? .null,
                    .integer(Int64(chunks.count)),
                ])
                summary.filesIndexed += 1
                totalChunkCount += chunks.count
            }

            try database.execute("DELETE FROM repositories")
            let insertRepository = try database.prepare("INSERT OR REPLACE INTO repositories (path, name) VALUES (?, ?)")
            for repositoryRoot in repositoryRoots {
                try insertRepository.run([.text(repositoryRoot), .text((repositoryRoot as NSString).lastPathComponent)])
            }
            summary.chunkCount = totalChunkCount
            // N for the score floor, computed once per update; readers pick it up with the commit.
            try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('chunk_count', ?)")
                .run([.text(String(totalChunkCount))])
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        summary.seconds = Date().timeIntervalSince(startedAt)
        return summary
    }

    /// Depth-first walk. Never follows a symlinked folder; a symlinked file counts only under its resolved path, and
    /// only when that path sits inside a search folder.
    private func walk(
        directory: URL, repositoryRoot: String?, resolvedFolders: [URL], visitedPaths: inout Set<String>,
        foundFiles: inout [FoundFile], repositoryRoots: inout [String]
    ) {
        let entryKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: entryKeys, options: [])
        else { return }
        var currentRepositoryRoot = repositoryRoot
        // `.git` is a folder in a clone and a file in a worktree; either marks a repository.
        if entries.contains(where: { $0.lastPathComponent == ".git" }) {
            currentRepositoryRoot = directory.path
            if !repositoryRoots.contains(directory.path) { repositoryRoots.append(directory.path) }
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: Set(entryKeys)) else { continue }
            if values.isSymbolicLink == true {
                let resolvedURL = Self.fullyResolved(entry)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), !isDirectory.boolValue
                else { continue }
                guard resolvedFolders.contains(where: { Self.isInside(path: resolvedURL.path, folder: $0.path) }) else { continue }
                recordFile(at: resolvedURL, repositoryRoot: currentRepositoryRoot, visitedPaths: &visitedPaths, foundFiles: &foundFiles)
            } else if values.isDirectory == true {
                if BrainFileRules.isSkippedDirectoryForIndex(name: name) { continue }
                walk(
                    directory: entry, repositoryRoot: currentRepositoryRoot, resolvedFolders: resolvedFolders,
                    visitedPaths: &visitedPaths, foundFiles: &foundFiles, repositoryRoots: &repositoryRoots)
            } else {
                recordFile(at: entry, repositoryRoot: currentRepositoryRoot, visitedPaths: &visitedPaths, foundFiles: &foundFiles)
            }
        }
    }

    /// Notes a file for indexing only when it is a plain file with one name: a FIFO, a socket, a device or a file
    /// with a second hard link (which could be a link to a file outside the search folders) is left out.
    private func recordFile(
        at fileURL: URL, repositoryRoot: String?, visitedPaths: inout Set<String>, foundFiles: inout [FoundFile]
    ) {
        let path = fileURL.path
        guard !visitedPaths.contains(path) else { return }
        // `lstat`: the path is already a resolved one, so a symlink here is a file that changed since the listing.
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0, Self.isPlainSingleNameFile(fileStatus) else { return }
        let size = Int(fileStatus.st_size)
        guard BrainFileRules.isIndexableFile(path: path, byteCount: size) else { return }
        let modificationTime = Double(fileStatus.st_mtimespec.tv_sec) + Double(fileStatus.st_mtimespec.tv_nsec) / 1e9
        visitedPaths.insert(path)
        foundFiles.append(
            FoundFile(path: path, modificationTime: modificationTime, size: size, repositoryRoot: repositoryRoot))
    }

    private static func isPlainSingleNameFile(_ fileStatus: stat) -> Bool {
        (fileStatus.st_mode & S_IFMT) == S_IFREG && fileStatus.st_nlink == 1
    }

    /// The bytes of one indexable file, read from the descriptor the checks ran on, so a path swapped for a link or
    /// a FIFO between the check and the read cannot put other text under this path. `O_NOFOLLOW` refuses a symlink,
    /// `O_NONBLOCK` keeps the open of a FIFO from waiting for a writer. Nil when the file is not a plain file with
    /// one name, is over the size cap, or cannot be read.
    static func readIndexableFile(atPath path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0, isPlainSingleNameFile(fileStatus),
            Int(fileStatus.st_size) <= BrainFileRules.maximumIndexedFileBytes
        else { return nil }
        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let readCount = read(descriptor, &buffer, buffer.count)
            if readCount < 0 { return nil }
            if readCount == 0 { break }
            contents.append(buffer, count: readCount)
            // The file grew after the check: still over the cap.
            if contents.count > BrainFileRules.maximumIndexedFileBytes { return nil }
        }
        return contents
    }

    /// `realpath`, because Foundation's `resolvingSymlinksInPath` drops the `/private` prefix (`/var` stays `/var`),
    /// which would make the same file look like two paths.
    private static func fullyResolved(_ url: URL) -> URL {
        guard let resolvedPath = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath))
    }

    private static func isInside(path: String, folder: String) -> Bool {
        let folderPrefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(folderPrefix)
    }

    // MARK: Search

    /// The search behind `search_brain`: best passages first, at most `limit`.
    public func search(query: String, limit: Int) throws -> [BrainPassage] {
        readLock.lock()
        defer { readLock.unlock() }
        return try searchLocked(query: query, limit: limit)
    }

    private func searchLocked(query: String, limit: Int) throws -> [BrainPassage] {
        guard let matchExpression = BrainSearchQuery.matchExpression(for: query) else { return [] }
        var passages: [BrainPassage] = []
        try readDatabase.prepare(
            """
            SELECT path, heading, start_line, end_line, body, -\(Self.rankExpression) AS score
            FROM chunks WHERE chunks MATCH ? ORDER BY \(Self.rankExpression) LIMIT ?
            """
        ).rows([.text(matchExpression), .integer(Int64(max(limit, 1)))]) { row in
            passages.append(
                BrainPassage(
                    path: row.text(at: 0) ?? "", heading: row.text(at: 1), startLine: Int(row.integer(at: 2)),
                    endLine: Int(row.integer(at: 3)), text: row.text(at: 4) ?? "", score: row.real(at: 5)))
        }
        return passages
    }

    /// The passages sent with a question: only those above the score floor, within the passage and size budget,
    /// boosted toward the project the front window names (`projectNames` adds the notes folder's project pages to
    /// the git repo folder names found while indexing). Empty when nothing clears the floor.
    ///
    /// `searchFolders` is the CURRENT folder list: a passage whose file is not readable under it (a folder removed in
    /// Settings whose rows are still in the index, or a path that should never have been stored) is dropped. Nil skips
    /// that check, for callers that have no list.
    public func passages(
        forQuestion question: String, frontAppName: String?, frontWindowTitle: String?, projectNames: [String],
        searchFolders: [URL]? = nil
    ) throws -> [BrainPassage] {
        readLock.lock()
        defer { readLock.unlock() }
        var candidates = try searchLocked(query: question, limit: Self.candidateCount)
        if let searchFolders {
            let reader = BrainFileReader(searchFolders: searchFolders)
            candidates = candidates.filter { (try? reader.resolveReadableFile($0.path)) != nil }
        }
        guard !candidates.isEmpty else { return [] }

        let allProjectNames = Set(projectNames + (try repositoryProjectNamesLocked()))
        let windowText = [frontWindowTitle, frontAppName].compactMap { $0 }.joined(separator: "\n")
        let matchedNames = allProjectNames.filter { BrainProjectBoost.windowText(windowText, mentions: $0) }
        if !matchedNames.isEmpty {
            for candidateIndex in 0..<candidates.count {
                if matchedNames.contains(where: { BrainProjectBoost.path(candidates[candidateIndex].path, belongsTo: $0) }) {
                    candidates[candidateIndex].score *= Self.projectBoostFactor
                }
            }
            candidates.sort { $0.score > $1.score }
        }

        let scoreFloor = Self.effectiveScoreFloor(override: Self.passageScoreFloor, chunkCount: try storedChunkCountLocked())
        guard let topScore = candidates.first?.score, topScore >= scoreFloor else { return [] }
        var chosen: [BrainPassage] = []
        var passagesPerFile: [String: Int] = [:]
        var charactersLeft = Self.maximumPassageCharacters
        for candidate in candidates {
            if chosen.count >= Self.maximumPassages { break }
            if candidate.score < scoreFloor || candidate.score < topScore * Self.relativeScoreFloor { continue }
            if passagesPerFile[candidate.path, default: 0] >= Self.maximumPassagesPerFile { continue }
            var passage = candidate
            if passage.text.count > charactersLeft {
                if charactersLeft < Self.minimumUsefulCutCharacters { continue }
                passage = Self.cut(passage, toCharacters: charactersLeft)
            }
            charactersLeft -= passage.text.count
            passagesPerFile[passage.path, default: 0] += 1
            chosen.append(passage)
        }
        return chosen
    }

    /// Keeps whole lines from the top of the passage while they fit, and moves `endLine` to match.
    private static func cut(_ passage: BrainPassage, toCharacters limit: Int) -> BrainPassage {
        let lines = passage.text.split(separator: "\n", omittingEmptySubsequences: false)
        var keptLineCount = 0
        var characterCount = 0
        while keptLineCount < lines.count {
            let lineCost = lines[keptLineCount].count + (keptLineCount > 0 ? 1 : 0)
            if characterCount + lineCost > limit { break }
            characterCount += lineCost
            keptLineCount += 1
        }
        var cutPassage = passage
        // One very long line still has to fit: keep its head.
        if keptLineCount == 0 {
            cutPassage.text = String(passage.text.prefix(limit))
            return cutPassage
        }
        cutPassage.text = lines[0..<keptLineCount].joined(separator: "\n")
        cutPassage.endLine = passage.startLine + keptLineCount - 1
        return cutPassage
    }

    // MARK: Lists

    /// Absolute paths of indexed files with exactly this file name (the routing list is found as `registry.md`).
    public func indexedFiles(named fileName: String) throws -> [String] {
        readLock.lock()
        defer { readLock.unlock() }
        var paths: [String] = []
        try readDatabase.prepare("SELECT path FROM files").rows { row in
            let path = row.text(at: 0) ?? ""
            if (path as NSString).lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame { paths.append(path) }
        }
        return paths.sorted()
    }

    /// Folder names of the git repos found while indexing.
    public func repositoryProjectNames() throws -> [String] {
        readLock.lock()
        defer { readLock.unlock() }
        return try repositoryProjectNamesLocked()
    }

    private func repositoryProjectNamesLocked() throws -> [String] {
        var names = Set<String>()
        try readDatabase.prepare("SELECT name FROM repositories").rows { row in
            if let name = row.text(at: 0) { names.insert(name) }
        }
        return names.sorted()
    }

    /// The floor in force now: the override, or the curve at the chunk count the last update stored.
    func currentScoreFloor() -> Double {
        readLock.lock()
        defer { readLock.unlock() }
        return Self.effectiveScoreFloor(override: Self.passageScoreFloor, chunkCount: (try? storedChunkCountLocked()) ?? 0)
    }

    /// N for the score floor: the chunk count the last update stored. 0 for an index built before it was stored.
    private func storedChunkCountLocked() throws -> Int {
        var chunkCount = 0
        try readDatabase.prepare("SELECT value FROM meta WHERE key = 'chunk_count'").rows { row in
            chunkCount = Int(row.text(at: 0) ?? "") ?? 0
        }
        return chunkCount
    }
}
