import Foundation

/// Helpers for the search-folder list the app keeps in Settings.
public enum BrainServiceFolders {
    /// Absolute folder URLs for the saved paths: `~` expanded, blanks dropped, trailing slashes removed.
    /// `homeDirectory` is what `~` stands for; nil means the signed-in user's home folder. Tests pass a temp folder.
    public static func expand(paths: [String], homeDirectory: URL? = nil) -> [URL] {
        var folders: [URL] = []
        for rawPath in paths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            var expanded = NSString(string: trimmed).expandingTildeInPath
            if let homeDirectory {
                if trimmed == "~" { expanded = homeDirectory.path }
                else if trimmed.hasPrefix("~/") { expanded = homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))).path }
            }
            folders.append(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
        }
        return folders
    }

    /// Why a folder may not be a search folder, or nil when it may. Refused (after `~` expansion, `..` folding and
    /// symlink resolution): the root folder, the home folder, any folder that contains the home folder (`/Users`,
    /// `/System/Volumes/Data`), and `~/Library` with everything in it (mail, messages, keychains, browser data). Each
    /// would put keys, logins or mail the user owns inside the boundary the file reader protects.
    public static func refusalReason(for folder: URL, homeDirectory: URL? = nil) -> String? {
        // A folder that does not exist yet is still judged, by its nearest existing parent plus the missing rest.
        let folderPath = BrainFileReader.resolvedPathAllowingMissingTail(of: folder.path)
        let homePath = resolvedPath(of: (homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory())).path)
            ?? ((homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory())).path as NSString).standardizingPath
        if folderPath == "/" { return "The whole disk cannot be a search folder. Pick a folder inside it." }
        // The same home folder is also reachable through the data volume's own mount, which realpath leaves alone.
        let homeNames = [homePath, "/System/Volumes/Data" + homePath]
        for homeName in homeNames {
            if folderPath == homeName {
                return "The home folder cannot be a search folder. Pick a folder inside it."
            }
            // Component-wise: "/Users" contains "/Users/joe", "/Users2" does not.
            if homeName.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/") {
                return "A folder that contains the home folder cannot be a search folder. Pick a folder inside it."
            }
            let libraryPath = homeName + "/Library"
            if folderPath == libraryPath || folderPath.hasPrefix(libraryPath + "/") {
                return "The Library folder holds mail, messages and logins, so it cannot be a search folder."
            }
        }
        return nil
    }

    /// The folders that may be search folders: the root and home folders are dropped.
    public static func allowed(_ folders: [URL], homeDirectory: URL? = nil) -> [URL] {
        folders.filter { refusalReason(for: $0, homeDirectory: homeDirectory) == nil }
    }

    private static func resolvedPath(of path: String) -> String? {
        BrainFileReader.resolvedPath(of: path)
    }

    /// True when the path is an existing folder this app can list and may search (not the root or home folder).
    public static func isReadableFolder(_ folder: URL) -> Bool {
        guard refusalReason(for: folder) == nil else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// The first folder that is missing, not a folder, or not readable.
    public static func firstUnreadable(_ folders: [URL]) -> URL? {
        folders.first { !isReadableFolder($0) }
    }

    /// The folders that can be indexed; an unreadable one is skipped so the others still index.
    public static func readable(_ folders: [URL]) -> [URL] {
        folders.filter { isReadableFolder($0) }
    }

    /// The path with the home folder shown as `~`, only when the home folder is a whole leading path component.
    public static func abbreviated(path: String, homeDirectory: URL) -> String {
        let homePath = homeDirectory.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
