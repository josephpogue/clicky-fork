import Foundation
import Testing

@testable import ClickyCore

@Suite("Brain service map paths")
struct BrainServiceMapPathsTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("svc-maps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# x\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolved(_ url: URL) -> String {
        guard let pointer = realpath(url.path, nil) else { return url.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    @Test("the knowledge base index comes first when it sits inside a search folder, then registries")
    func indexThenRegistries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        try write(notes.appendingPathComponent("Wiki/index.md"))
        let registry = resolved(notes) + "/routing/registry.md"
        let paths = BrainServiceMapPaths.make(notesFolder: notes, searchFolders: [notes], registryPaths: [registry])
        #expect(paths == [resolved(notes) + "/Wiki/index.md", registry])
    }

    @Test("an index outside every search folder is left out")
    func indexOutside() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        let other = root.appendingPathComponent("other")
        try write(notes.appendingPathComponent("Wiki/index.md"))
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(BrainServiceMapPaths.make(notesFolder: notes, searchFolders: [other], registryPaths: []).isEmpty)
    }

    @Test("a folder name that only shares a prefix does not count as inside")
    func prefixLookalike() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        let lookalike = root.appendingPathComponent("notes-old")
        try write(notes.appendingPathComponent("Wiki/index.md"))
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        #expect(BrainServiceMapPaths.make(notesFolder: notes, searchFolders: [lookalike], registryPaths: []).isEmpty)
    }

    @Test("a notes folder that is a symlink into a search folder still counts")
    func symlinkedNotesFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/notes")
        try write(real.appendingPathComponent("Wiki/index.md"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let paths = BrainServiceMapPaths.make(
            notesFolder: link, searchFolders: [root.appendingPathComponent("real")], registryPaths: [])
        #expect(paths == [resolved(real) + "/Wiki/index.md"])
    }

    @Test("a search folder that is a symlink to the notes folder counts too")
    func symlinkedSearchFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try write(real.appendingPathComponent("Wiki/index.md"))
        let link = root.appendingPathComponent("linked-search")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let paths = BrainServiceMapPaths.make(notesFolder: real, searchFolders: [link], registryPaths: [])
        #expect(paths == [resolved(real) + "/Wiki/index.md"])
    }

    @Test("repeats are dropped and the order is kept")
    func repeats() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        try write(notes.appendingPathComponent("Wiki/index.md"))
        let indexPath = resolved(notes) + "/Wiki/index.md"
        let paths = BrainServiceMapPaths.make(
            notesFolder: notes, searchFolders: [notes], registryPaths: ["/b/registry.md", indexPath, "/a/registry.md", "/b/registry.md"])
        #expect(paths == [indexPath, "/b/registry.md", "/a/registry.md"])
    }

    @Test("without a notes folder or index file only registries are returned")
    func noNotesFolder() throws {
        #expect(BrainServiceMapPaths.make(notesFolder: nil, searchFolders: [], registryPaths: ["/r/registry.md"]) == ["/r/registry.md"])
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BrainServiceMapPaths.make(notesFolder: root, searchFolders: [root], registryPaths: []).isEmpty)
    }
}
