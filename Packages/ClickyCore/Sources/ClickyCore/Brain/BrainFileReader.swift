import Foundation

/// Reads lines of one text file for `read_brain_file`, only inside the search folders. Owned by the brain-files slice.
/// This is the security boundary of the brain feature: a path is opened only after every symlink and `..` is resolved
/// and the real location is inside a (resolved) search folder and not on the never-readable list.
public struct BrainFileReader: Sendable {
    public static let maximumLinesPerCall = 200
    public static let maximumCharactersPerCall = 16_000
    /// How much of a file is looked at to decide whether it is text.
    static let textSniffByteCount = 8_192

    public let searchFolders: [URL]

    /// The search folders after resolving symlinks, computed once. A folder that does not exist keeps its standardized path.
    private let resolvedSearchFolderPaths: [String]

    public init(searchFolders: [URL]) {
        self.searchFolders = searchFolders
        self.resolvedSearchFolderPaths = searchFolders.map { folder in
            Self.resolvedPath(of: folder.path) ?? (folder.path as NSString).standardizingPath
        }
    }

    /// The file a path names, after resolving symlinks, when it may be read. Throws `BrainFileRefusal` otherwise.
    public func resolveReadableFile(_ path: String) throws -> URL {
        let expandedPath = Self.expandingTilde(path)

        // Candidate absolute paths: an absolute path stands alone; a relative one is tried under each folder in order.
        let candidatePaths: [String]
        if expandedPath.hasPrefix("/") {
            candidatePaths = [expandedPath]
        } else {
            candidatePaths = resolvedSearchFolderPaths.map { ($0 as NSString).appendingPathComponent(expandedPath) }
        }
        guard !candidatePaths.isEmpty else { throw BrainFileRefusal.outsideSearchFolders }

        // The first candidate that exists wins; when none exists the first one carries the refusal.
        let chosenCandidatePath = candidatePaths.first(where: { Self.resolvedPath(of: $0) != nil }) ?? candidatePaths[0]

        // Checked before existence, so the model cannot learn whether a secret exists.
        if BrainFileRules.isNeverReadable(path: chosenCandidatePath) { throw BrainFileRefusal.neverReadable }
        if candidatePaths.contains(where: { BrainFileRules.isNeverReadable(path: $0) }) {
            throw BrainFileRefusal.neverReadable
        }

        let resolvedFilePath = Self.resolvedPathAllowingMissingTail(of: chosenCandidatePath)
        if BrainFileRules.isNeverReadable(path: resolvedFilePath) { throw BrainFileRefusal.neverReadable }
        guard isInsideSearchFolders(resolvedFilePath) else { throw BrainFileRefusal.outsideSearchFolders }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedFilePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BrainFileRefusal.notFound
        }
        guard Self.looksLikeText(atPath: resolvedFilePath) else { throw BrainFileRefusal.notText }
        return URL(fileURLWithPath: resolvedFilePath)
    }

    /// `lineCount` lines from `startLine` (1-based), capped by `maximumLinesPerCall` and `maximumCharactersPerCall`.
    public func read(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        let fileURL = try resolveReadableFile(path)
        guard let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            throw BrainFileRefusal.notFound
        }
        let fileText = String(decoding: fileData, as: UTF8.self)
        var allLines = fileText.components(separatedBy: "\n")
        if allLines.last == "" { allLines.removeLast() }
        let totalLineCount = allLines.count

        let firstLineNumber = max(startLine, 1)
        let askedLineCount = max(lineCount, 1)
        let allowedLineCount = min(askedLineCount, Self.maximumLinesPerCall)
        let firstIndex = firstLineNumber - 1
        guard firstIndex < totalLineCount else {
            return BrainFileExcerpt(
                path: fileURL.path, startLine: firstLineNumber, lines: [], totalLineCount: totalLineCount,
                wasCappedByLimit: false)
        }
        let availableLineCount = totalLineCount - firstIndex
        let lineLimitIndex = firstIndex + min(allowedLineCount, availableLineCount)

        // Add lines while the joined size (lines plus one newline between each) stays within the character cap,
        // but always keep the first line, cut to the cap when it alone is longer.
        var returnedLines: [String] = []
        var joinedCharacterCount = 0
        var firstLineWasCut = false
        var lineIndex = firstIndex
        while lineIndex < lineLimitIndex {
            let line = allLines[lineIndex]
            let separatorCount = returnedLines.isEmpty ? 0 : 1
            let lineCharacterCount = line.count
            if joinedCharacterCount + separatorCount + lineCharacterCount > Self.maximumCharactersPerCall {
                if returnedLines.isEmpty {
                    returnedLines.append(String(line.prefix(Self.maximumCharactersPerCall)))
                    firstLineWasCut = true
                }
                break
            }
            returnedLines.append(line)
            joinedCharacterCount += separatorCount + lineCharacterCount
            lineIndex += 1
        }

        // Capped when we returned fewer lines than were asked and exist, or when a single line was cut.
        let wantedLineCount = min(askedLineCount, availableLineCount)
        let wasCappedByLimit = returnedLines.count < wantedLineCount || firstLineWasCut
        return BrainFileExcerpt(
            path: fileURL.path, startLine: firstLineNumber, lines: returnedLines, totalLineCount: totalLineCount,
            wasCappedByLimit: wasCappedByLimit)
    }

    // MARK: Path handling

    private func isInsideSearchFolders(_ resolvedFilePath: String) -> Bool {
        for folderPath in resolvedSearchFolderPaths {
            if resolvedFilePath == folderPath { return true }
            // Component-wise: "/a/brain2" is not inside "/a/brain".
            let folderPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            if resolvedFilePath.hasPrefix(folderPrefix) { return true }
        }
        return false
    }

    static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    /// `realpath(3)`: every symlink and `..` resolved. Nil when the path does not exist.
    static func resolvedPath(of path: String) -> String? {
        guard let resolvedCString = realpath(path, nil) else { return nil }
        defer { free(resolvedCString) }
        return String(cString: resolvedCString)
    }

    /// Resolves the longest existing leading part with realpath and appends the missing rest with `.` and `..`
    /// folded lexically, so a missing file is still placed inside or outside the folders for the refusal.
    static func resolvedPathAllowingMissingTail(of path: String) -> String {
        if let resolved = resolvedPath(of: path) { return resolved }
        var existingPart = path
        var missingComponents: [String] = []
        while existingPart != "/" && !existingPart.isEmpty {
            if let resolvedExisting = resolvedPath(of: existingPart) {
                var resultComponents = resolvedExisting.split(separator: "/").map(String.init)
                for component in missingComponents.reversed() {
                    if component == "." || component.isEmpty { continue }
                    if component == ".." { _ = resultComponents.popLast() } else { resultComponents.append(component) }
                }
                return "/" + resultComponents.joined(separator: "/")
            }
            missingComponents.append((existingPart as NSString).lastPathComponent)
            existingPart = (existingPart as NSString).deletingLastPathComponent
        }
        return (path as NSString).standardizingPath
    }

    // MARK: Text check

    /// True when the first 8,192 bytes hold no NUL byte and are valid UTF-8 (a multi-byte character cut at the
    /// boundary is allowed).
    static func looksLikeText(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let sniffedData = try? handle.read(upToCount: textSniffByteCount) else { return false }
        if sniffedData.contains(0) { return false }
        if String(data: sniffedData, encoding: .utf8) != nil { return true }
        guard sniffedData.count == textSniffByteCount else { return false }
        // Drop up to three trailing bytes: the start of a character the boundary cut in two.
        for droppedByteCount in 1...3 where String(data: sniffedData.dropLast(droppedByteCount), encoding: .utf8) != nil {
            return true
        }
        return false
    }
}
