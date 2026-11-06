import Foundation

/// A temporary folder tree for the FX2 brain tests. Never reads the real brain.
struct BrainTempTree {
    let root: URL

    init(name: String = "brain-fx2") throws {
        // Resolved, so `/var` and `/private/var` never make two spellings of one folder.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(base.path, nil)))
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
