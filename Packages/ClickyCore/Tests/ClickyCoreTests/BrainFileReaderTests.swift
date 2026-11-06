import Foundation
import Testing
@testable import ClickyCore

/// Every folder here is a fresh temp folder; the real brain is never read.
struct BrainFileReaderTests {
    private struct Fixture {
        let root: URL       // resolved temp root
        let folder: URL     // F, the search folder
        let outsideFile: URL
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFixture() throws -> Fixture {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: BrainFileReader.resolvedPath(of: tempRoot.path)!)
        let folder = root.appendingPathComponent("F", isDirectory: true)
        try write("alpha\nbeta\n", to: folder.appendingPathComponent("notes/a.md"))
        let outsideFile = root.appendingPathComponent("outside.md")
        try write("outside\n", to: outsideFile)
        try write("x\n", to: root.appendingPathComponent("outside-dir/x.md"))
        return Fixture(root: root, folder: folder, outsideFile: outsideFile)
    }

    private func link(_ linkURL: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)
    }

    private func refusal(_ reader: BrainFileReader, _ path: String) -> BrainFileRefusal? {
        do { _ = try reader.resolveReadableFile(path); return nil } catch let error as BrainFileRefusal { return error } catch { return nil }
    }

    @Test func readableByRelativeAbsoluteAndDotDotPaths() throws {
        let fixture = try makeFixture()
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        let absolutePath = fixture.folder.appendingPathComponent("notes/a.md").path
        #expect(try reader.resolveReadableFile("notes/a.md").path == absolutePath)
        #expect(try reader.resolveReadableFile(absolutePath).path == absolutePath)
        #expect(try reader.resolveReadableFile(fixture.folder.path + "/../F/notes/a.md").path == absolutePath)
    }

    @Test func outsidePathsAreRefused() throws {
        let fixture = try makeFixture()
        try link(fixture.folder.appendingPathComponent("link-out.md"), to: fixture.outsideFile)
        try link(fixture.folder.appendingPathComponent("linked-dir"), to: fixture.root.appendingPathComponent("outside-dir"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        #expect(refusal(reader, fixture.folder.path + "/link-out.md") == .outsideSearchFolders)
        #expect(refusal(reader, fixture.folder.path + "/linked-dir/x.md") == .outsideSearchFolders)
        #expect(refusal(reader, fixture.folder.path + "/../outside.md") == .outsideSearchFolders)
        #expect(refusal(reader, "/etc/hosts") == .outsideSearchFolders)
        #expect(refusal(reader, "../outside.md") == .outsideSearchFolders)
        #expect(refusal(reader, fixture.folder.path + "/../nope.md") == .outsideSearchFolders)
    }

    @Test func siblingFolderWithSharedPrefixIsOutside() throws {
        let fixture = try makeFixture()
        let sibling = fixture.root.appendingPathComponent("F2/a.md")
        try write("x\n", to: sibling)
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        #expect(refusal(reader, sibling.path) == .outsideSearchFolders)
    }

    @Test func aSearchFolderThatIsASymlinkReadsByBothPaths() throws {
        let fixture = try makeFixture()
        let realFolder = fixture.root.appendingPathComponent("R", isDirectory: true)
        try write("hi\n", to: realFolder.appendingPathComponent("a.md"))
        let linkedFolder = fixture.root.appendingPathComponent("G")
        try link(linkedFolder, to: realFolder)
        let reader = BrainFileReader(searchFolders: [linkedFolder])
        #expect(try reader.resolveReadableFile(linkedFolder.path + "/a.md").path == realFolder.path + "/a.md")
        #expect(try reader.resolveReadableFile(realFolder.path + "/a.md").path == realFolder.path + "/a.md")
        #expect(try reader.resolveReadableFile("a.md").path == realFolder.path + "/a.md")
    }

    @Test func linkInsideTheFolderResolvesToItsTarget() throws {
        let fixture = try makeFixture()
        try link(fixture.folder.appendingPathComponent("inner-link.md"), to: fixture.folder.appendingPathComponent("notes/a.md"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        let excerpt = try reader.read(path: "inner-link.md", startLine: 1, lineCount: 5)
        #expect(excerpt.path == fixture.folder.path + "/notes/a.md")
        #expect(excerpt.lines == ["alpha", "beta"])
    }

    @Test(arguments: [
        ".env", "app/.env.production.local", "prod.env", "keys/server.pem", "id_ed25519", "aws-credentials.json",
        "notes/api-token.txt", ".git/config", "node_modules/x/README.md", ".ssh/config",
    ])
    func secretsAreRefusedWhetherOrNotTheyExist(relativePath: String) throws {
        let fixture = try makeFixture()
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        #expect(refusal(reader, relativePath) == .neverReadable)
        try write("secret\n", to: fixture.folder.appendingPathComponent(relativePath))
        #expect(refusal(reader, relativePath) == .neverReadable)
        #expect(refusal(reader, fixture.folder.path + "/" + relativePath) == .neverReadable)
    }

    @Test func linkToASecretIsRefusedByItsResolvedPath() throws {
        let fixture = try makeFixture()
        try write("k=v\n", to: fixture.folder.appendingPathComponent(".env"))
        try link(fixture.folder.appendingPathComponent("safe-link.md"), to: fixture.folder.appendingPathComponent(".env"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        #expect(refusal(reader, "safe-link.md") == .neverReadable)
    }

    @Test func nonTextMissingAndDirectoryFiles() throws {
        let fixture = try makeFixture()
        try Data([0x61, 0x00, 0x62]).write(to: fixture.folder.appendingPathComponent("bin.md"))
        try Data([0xFF, 0xFE, 0x41]).write(to: fixture.folder.appendingPathComponent("badutf8.md"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        #expect(refusal(reader, "bin.md") == .notText)
        #expect(refusal(reader, "badutf8.md") == .notText)
        #expect(refusal(reader, "missing.md") == .notFound)
        #expect(refusal(reader, "notes") == .notFound)
    }

    @Test func multiByteCharacterCutAtTheSniffBoundaryIsStillText() throws {
        let fixture = try makeFixture()
        // 8,191 ASCII bytes then a 3-byte character, so the 8,192-byte sniff cuts it after one byte.
        let text = String(repeating: "a", count: 8_191) + "\u{20AC}" + "\n"
        try write(text, to: fixture.folder.appendingPathComponent("edge.md"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        #expect(refusal(reader, "edge.md") == nil)
    }

    @Test func lineWindowsAndCaps() throws {
        let fixture = try makeFixture()
        let lines = (1...450).map { "line \($0)" }
        try write(lines.joined(separator: "\n") + "\n", to: fixture.folder.appendingPathComponent("long.md"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])

        let first = try reader.read(path: "long.md", startLine: 1, lineCount: 1000)
        #expect(first.lines.count == 200 && first.wasCappedByLimit && first.totalLineCount == 450)
        #expect(first.lines.first == "line 1" && first.lines.last == "line 200")

        let tail = try reader.read(path: "long.md", startLine: 401, lineCount: 200)
        #expect(tail.lines.count == 50 && !tail.wasCappedByLimit && tail.startLine == 401)

        let past = try reader.read(path: "long.md", startLine: 999, lineCount: 5)
        #expect(past.lines.isEmpty && past.totalLineCount == 450 && !past.wasCappedByLimit)

        let clamped = try reader.read(path: "long.md", startLine: -3, lineCount: 0)
        #expect(clamped.startLine == 1 && clamped.lines == ["line 1"] && !clamped.wasCappedByLimit)
    }

    @Test func characterCapStopsBeforeSixteenThousand() throws {
        let fixture = try makeFixture()
        let line = String(repeating: "x", count: 100)
        try write(Array(repeating: line, count: 300).joined(separator: "\n") + "\n", to: fixture.folder.appendingPathComponent("wide.md"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        let excerpt = try reader.read(path: "wide.md", startLine: 1, lineCount: 200)
        // Joined with one newline between lines: n lines hold 101 * n - 1 characters, so 158 fit (15,957) and 159 do not (16,058).
        #expect(excerpt.lines.count == 158)
        #expect(excerpt.lines.joined(separator: "\n").count <= BrainFileReader.maximumCharactersPerCall)
        #expect(excerpt.wasCappedByLimit)
    }

    @Test func aSingleHugeLineIsCutToTheCap() throws {
        let fixture = try makeFixture()
        try write(String(repeating: "y", count: 20_000) + "\n", to: fixture.folder.appendingPathComponent("huge.md"))
        let reader = BrainFileReader(searchFolders: [fixture.folder])
        let excerpt = try reader.read(path: "huge.md", startLine: 1, lineCount: 1)
        #expect(excerpt.lines.count == 1 && excerpt.lines[0].count == 16_000 && excerpt.wasCappedByLimit)
    }
}
