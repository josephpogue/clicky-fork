import Foundation

/// Reads lines of one text file for `read_brain_file`, only inside the search folders. Owned by the brain-files slice.
/// This is the security boundary of the brain feature: a path is opened only after every symlink and `..` is resolved
/// and the real location is inside a (resolved) search folder and not on the never-readable list.
public struct BrainFileReader: Sendable {
    public static let maximumLinesPerCall = 200
    public static let maximumCharactersPerCall = 16_000
    /// How much of a file is looked at to decide whether it is text.
    static let textSniffByteCount = 8_192
    public static let maximumFileBytes = 8 * 1024 * 1024

    public let searchFolders: [URL]

    /// The search folders after resolving symlinks, computed once. A folder that does not exist keeps its standardized path.
    private let resolvedSearchFolderPaths: [String]

    /// The search folders as given, standardized (no symlink resolution), for checking the path as the model typed it.
    private let givenSearchFolderPaths: [String]

    /// The root folder and the home folder are never search folders, whatever the caller passes: either would put every
    /// key and login of the user inside the boundary.
    public init(searchFolders requestedSearchFolders: [URL]) {
        let searchFolders = BrainServiceFolders.allowed(requestedSearchFolders)
        self.searchFolders = searchFolders
        self.givenSearchFolderPaths = searchFolders.map { ($0.path as NSString).standardizingPath }
        self.resolvedSearchFolderPaths = searchFolders.map { folder in
            Self.resolvedPath(of: folder.path) ?? (folder.path as NSString).standardizingPath
        }
    }

    /// The file a path names, after resolving symlinks, when it may be read. Throws `BrainFileRefusal` otherwise.
    public func resolveReadableFile(_ path: String) throws -> URL {
        let resolvedFilePath = try permittedResolvedPath(path)
        let descriptor = try openRegularFile(atPath: resolvedFilePath)
        defer { close(descriptor) }
        let sniffedData = try Self.readBytes(from: descriptor, upTo: Self.textSniffByteCount)
        guard Self.looksLikeText(sniffedData) else { throw BrainFileRefusal.notText }
        return URL(fileURLWithPath: resolvedFilePath)
    }

    /// The path rules: resolves the path and throws unless it is inside a search folder and not on a never-readable
    /// list. Does not open the file.
    private func permittedResolvedPath(_ path: String) throws -> String {
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
        try refuseUnlessPermitted(resolvedPath: resolvedFilePath)

        // Everything under a hidden folder inside a search folder (`.claude/settings.local.json`, `.config/gh/hosts.yml`)
        // holds tool state and logins. The search folder itself may sit inside a hidden folder.
        for pathToCheck in candidatePaths + [chosenCandidatePath]
        where isUnderHiddenFolderBelowEverySearchFolder(pathToCheck) {
            throw BrainFileRefusal.neverReadable
        }
        return resolvedFilePath
    }

    /// The rules every real path must pass, run on the path before the open and again on the opened descriptor's path:
    /// not on the never-readable list, inside a search folder, and not under a hidden folder below it.
    private func refuseUnlessPermitted(resolvedPath: String) throws {
        if BrainFileRules.isNeverReadable(path: resolvedPath) { throw BrainFileRefusal.neverReadable }
        guard isInsideSearchFolders(resolvedPath) else { throw BrainFileRefusal.outsideSearchFolders }
        if isUnderHiddenFolderBelowEverySearchFolder(resolvedPath) { throw BrainFileRefusal.neverReadable }
    }

    /// Opens the file once and checks the descriptor, so what is read is what was checked (no swap between a path
    /// check and the read). The caller gets the whole content, at most `maximumFileBytes`.
    private func readVerifiedContent(of path: String) throws -> (url: URL, content: Data) {
        let resolvedFilePath = try permittedResolvedPath(path)
        let descriptor = try openRegularFile(atPath: resolvedFilePath)
        defer { close(descriptor) }
        let content = try Self.readBytes(from: descriptor, upTo: Self.maximumFileBytes + 1)
        // The file grew after the size check.
        if content.count > Self.maximumFileBytes { throw BrainFileRefusal.notText }
        guard Self.looksLikeText(content) else { throw BrainFileRefusal.notText }
        return (URL(fileURLWithPath: resolvedFilePath), content)
    }

    /// Opens without following a symlink in ANY component (`O_NOFOLLOW_ANY`; `O_NOFOLLOW` covers only the last one, so a
    /// parent folder swapped for a symlink after the path check would read outside) or blocking, and accepts only a single-name regular file within the size cap.
    func openRegularFile(atPath path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        // A path that vanished, or a symlink swapped in since the check, is simply not there.
        guard descriptor >= 0 else { throw BrainFileRefusal.notFound }
        var fileStatus = stat()
        do {
            guard fstat(descriptor, &fileStatus) == 0 else { throw BrainFileRefusal.notFound }
            // A named pipe, socket, device or folder is not a file: with O_NONBLOCK the open above cannot hang on a pipe.
            guard (fileStatus.st_mode & S_IFMT) == S_IFREG else { throw BrainFileRefusal.notFound }
            // A second name for the same bytes (a hard link to a key file called notes.md) passes every path rule.
            guard fileStatus.st_nlink == 1 else { throw BrainFileRefusal.neverReadable }
            guard fileStatus.st_size <= Int64(Self.maximumFileBytes) else { throw BrainFileRefusal.notText }
            try verifyDescriptorPath(descriptor, expectedPath: path)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Reads the path the kernel says the descriptor is open on (`F_GETPATH`) and runs the path rules on it again, so a
    /// swap between the check and the open cannot read a file outside the folders. A path that differs from the one
    /// checked is refused too.
    func verifyDescriptorPath(_ descriptor: Int32, expectedPath: String) throws {
        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else { throw BrainFileRefusal.notFound }
        let openedPath = String(cString: pathBuffer)
        try refuseUnlessPermitted(resolvedPath: openedPath)
        guard openedPath == expectedPath else { throw BrainFileRefusal.notFound }
    }

    private static func readBytes(from descriptor: Int32, upTo byteLimit: Int) throws -> Data {
        var content = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while content.count < byteLimit {
            let wantedCount = min(buffer.count, byteLimit - content.count)
            let readCount = Darwin.read(descriptor, &buffer, wantedCount)
            if readCount < 0 {
                if errno == EINTR { continue }
                throw BrainFileRefusal.notFound
            }
            if readCount == 0 { break }
            content.append(buffer, count: readCount)
        }
        return content
    }

    /// True when the path lies in a search folder only through a hidden folder below it. When a search folder nests
    /// inside another (`~/brain` and `~/brain/.claude/routing`), the nearer folder makes the path fine.
    private func isUnderHiddenFolderBelowEverySearchFolder(_ path: String) -> Bool {
        var foundContainingFolder = false
        for folderPath in resolvedSearchFolderPaths + givenSearchFolderPaths {
            let folderPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            guard path.hasPrefix(folderPrefix) else { continue }
            foundContainingFolder = true
            let componentsBelow = path.dropFirst(folderPrefix.count).split(separator: "/").map(String.init)
            var hiddenFolderFound = false
            // The last component is the file itself; a hidden leaf file is judged by the other rules alone.
            for componentIndex in 0..<max(componentsBelow.count - 1, 0) {
                let component = componentsBelow[componentIndex]
                if component.hasPrefix(".") && component != "." && component != ".." { hiddenFolderFound = true }
            }
            if !hiddenFolderFound { return false }
        }
        return foundContainingFolder
    }

    /// `lineCount` lines from `startLine` (1-based), capped by `maximumLinesPerCall` and `maximumCharactersPerCall`.
    public func read(path: String, startLine: Int, lineCount: Int) throws -> BrainFileExcerpt {
        let (fileURL, fileData) = try readVerifiedContent(of: path)
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
    static func looksLikeText(_ content: Data) -> Bool {
        let sniffedData = content.prefix(textSniffByteCount)
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
