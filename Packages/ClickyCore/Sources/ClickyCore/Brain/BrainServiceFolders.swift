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

    /// True when the path is an existing folder this app can list.
    public static func isReadableFolder(_ folder: URL) -> Bool {
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
