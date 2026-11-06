import Foundation

/// The maps the instructions name: the knowledge base index under the notes folder and every indexed `registry.md`.
public enum BrainServiceMapPaths {
    /// `<notes folder>/Wiki/index.md` first, when that file exists and sits inside a search folder (compared by path
    /// component after resolving symlinks on both sides: the notes folder can be a symlink), then the registry paths,
    /// without repeats. Paths are returned resolved, the same form the index stores.
    public static func make(notesFolder: URL?, searchFolders: [URL], registryPaths: [String]) -> [String] {
        var paths: [String] = []
        if let notesFolder {
            let indexFile = notesFolder.appendingPathComponent("Wiki", isDirectory: true).appendingPathComponent("index.md")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: indexFile.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                let resolvedIndex = resolved(indexFile)
                let resolvedFolders = searchFolders.map { resolved($0) }
                if resolvedFolders.contains(where: { isInside(path: resolvedIndex, folder: $0) }) {
                    paths.append(resolvedIndex.path)
                }
            }
        }
        for registryPath in registryPaths where !paths.contains(registryPath) {
            paths.append(registryPath)
        }
        return paths
    }

    private static func resolved(_ url: URL) -> URL {
        guard let resolvedPath = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath))
    }

    /// Whole components only, so `/notes-old` is not inside `/notes`.
    private static func isInside(path: URL, folder: URL) -> Bool {
        let pathComponents = path.pathComponents
        let folderComponents = folder.pathComponents
        guard pathComponents.count > folderComponents.count else { return false }
        for componentIndex in 0..<folderComponents.count where pathComponents[componentIndex] != folderComponents[componentIndex] {
            return false
        }
        return true
    }
}
