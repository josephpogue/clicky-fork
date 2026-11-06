import Foundation
import Testing

@testable import ClickyCore

/// Finding V1.1: on a case-insensitive disk a path or folder spelt in another case than the disk must still read, and
/// every refusal stays. Temp folders only.
struct BrainFileReaderCaseTests {
    /// True when the temp volume treats `Name` and `name` as one file; the case asserts are skipped on a case-sensitive one.
    private func volumeIsCaseInsensitive(_ tree: BrainTempTree) -> Bool {
        (try? tree.write("CaseProbe.txt", "x")) != nil && FileManager.default.fileExists(atPath: tree.url("caseprobe.txt").path)
    }

    private func makeTree() throws -> (tree: BrainTempTree, folder: URL) {
        let tree = try BrainTempTree(name: "brain-case")
        try tree.write("cs/Notes/A.md", "alpha\nbeta\n")
        try tree.write("outside.md", "outside\n")
        try tree.write("cs/.ENV", "SECRET=1\n")
        try tree.write("cs/Keys/Server.PEM", "pem\n")
        return (tree, tree.url("cs"))
    }

    @Test func aReaderGivenTheDiskSpellingReadsEveryCaseSpelling() throws {
        let (tree, folder) = try makeTree()
        defer { tree.cleanUp() }
        guard volumeIsCaseInsensitive(tree) else { print("skipped: case-sensitive temp volume"); return }
        let reader = BrainFileReader(searchFolders: [folder])
        for spelling in ["cs/notes/a.md", "cs/Notes/A.md", "CS/notes/a.md"] {
            let excerpt = try reader.read(path: tree.url(spelling).path, startLine: 1, lineCount: 5)
            #expect(excerpt.path.hasSuffix("cs/Notes/A.md"), "\(spelling) gave \(excerpt.path)")
            #expect(excerpt.lines == ["alpha", "beta"])
            #expect(try reader.resolveReadableFile(tree.url(spelling).path).path.hasSuffix("cs/Notes/A.md"))
        }
        // A relative path under the folder, spelt in another case.
        #expect(try reader.read(path: "notes/a.md", startLine: 1, lineCount: 5).path.hasSuffix("cs/Notes/A.md"))
    }

    /// On this macOS `realpath` already returns the on-disk case, so the reader's own path check cannot be made to
    /// differ by case. The open's check can: a hand-built path in another case opens a descriptor whose `F_GETPATH` is
    /// the disk's spelling, which the old byte-equality refused as `.notFound`.
    @Test func theOpenAcceptsAPathSpeltInAnotherCase() throws {
        let (tree, folder) = try makeTree()
        defer { tree.cleanUp() }
        guard volumeIsCaseInsensitive(tree) else { print("skipped: case-sensitive temp volume"); return }
        let reader = BrainFileReader(searchFolders: [folder])
        let descriptor = try reader.openRegularFile(atPath: tree.url("CS/notes/a.md").path)
        close(descriptor)
    }

    @Test func aReaderGivenAnotherCaseSpellingOfTheFolderReadsToo() throws {
        let (tree, _) = try makeTree()
        defer { tree.cleanUp() }
        guard volumeIsCaseInsensitive(tree) else { print("skipped: case-sensitive temp volume"); return }
        let reader = BrainFileReader(searchFolders: [tree.url("CS")])
        for spelling in ["cs/notes/a.md", "cs/Notes/A.md", "CS/notes/a.md"] {
            let excerpt = try reader.read(path: tree.url(spelling).path, startLine: 1, lineCount: 5)
            #expect(excerpt.path.hasSuffix("cs/Notes/A.md"), "\(spelling) gave \(excerpt.path)")
        }
    }

    @Test func everyRefusalStaysWhateverTheCase() throws {
        let (tree, folder) = try makeTree()
        defer { tree.cleanUp() }
        try FileManager.default.createSymbolicLink(at: tree.url("cs/out.md"), withDestinationURL: tree.url("outside.md"))
        for reader in [BrainFileReader(searchFolders: [folder]), BrainFileReader(searchFolders: [tree.url("CS")])] {
            func refusal(_ path: String) -> BrainFileRefusal? {
                do { _ = try reader.resolveReadableFile(path); return nil } catch let error as BrainFileRefusal { return error } catch { return nil }
            }
            #expect(refusal(tree.url("cs/../outside.md").path) == .outsideSearchFolders)
            #expect(refusal(tree.url("cs/out.md").path) == .outsideSearchFolders)
            #expect(refusal(tree.url("cs/.ENV").path) == .neverReadable)
            #expect(refusal(tree.url("CS/.env").path) == .neverReadable)
            #expect(refusal(tree.url("cs/Keys/Server.PEM").path) == .neverReadable)
            #expect(refusal(tree.url("cs/keys/server.pem").path) == .neverReadable)
        }
    }
}
