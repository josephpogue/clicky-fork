import Foundation
import Testing

@testable import ClickyCore

@Suite("Brain service status line")
struct BrainServiceStatusTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func summary(indexed: Int, unchanged: Int) -> BrainIndexUpdateSummary {
        BrainIndexUpdateSummary(filesIndexed: indexed, filesUnchanged: unchanged, filesRemoved: 0, chunkCount: 0, seconds: 0)
    }

    @Test("no folders gives no line, even while a refresh runs")
    func noFolders() {
        let status = BrainServiceStatus.make(
            hasFolders: false, isRefreshing: true, lastSummary: summary(indexed: 3, unchanged: 0),
            firstUnreadableFolderPath: nil, homeDirectory: home)
        #expect(status == nil)
    }

    @Test("a running refresh shows Indexing as working")
    func indexing() {
        let status = BrainServiceStatus.make(
            hasFolders: true, isRefreshing: true, lastSummary: nil, firstUnreadableFolderPath: nil, homeDirectory: home)
        #expect(status == BrainServiceStatus(text: "Indexing...", kind: .working))
    }

    @Test("done counts indexed plus unchanged with a grouping separator")
    func doneCounts() {
        let status = BrainServiceStatus.make(
            hasFolders: true, isRefreshing: false, lastSummary: summary(indexed: 84, unchanged: 1_200),
            firstUnreadableFolderPath: nil, homeDirectory: home, locale: Locale(identifier: "en_US"))
        #expect(status == BrainServiceStatus(text: "1,284 notes indexed", kind: .ready))
    }

    @Test("one note and zero notes")
    func singularAndZero() {
        let one = BrainServiceStatus.make(
            hasFolders: true, isRefreshing: false, lastSummary: summary(indexed: 1, unchanged: 0),
            firstUnreadableFolderPath: nil, homeDirectory: home, locale: Locale(identifier: "en_US"))
        let zero = BrainServiceStatus.make(
            hasFolders: true, isRefreshing: false, lastSummary: summary(indexed: 0, unchanged: 0),
            firstUnreadableFolderPath: nil, homeDirectory: home, locale: Locale(identifier: "en_US"))
        #expect(one?.text == "1 note indexed")
        #expect(zero?.text == "0 notes indexed")
    }

    @Test("an unreadable folder shows a problem with the home folder as a tilde")
    func unreadable() {
        let status = BrainServiceStatus.make(
            hasFolders: true, isRefreshing: false, lastSummary: summary(indexed: 5, unchanged: 0),
            firstUnreadableFolderPath: "/Users/someone/notes", homeDirectory: home)
        #expect(status == BrainServiceStatus(text: "Could not read ~/notes", kind: .problem))
    }

    @Test("a path outside home keeps its full path, and a lookalike home prefix is not shortened")
    func abbreviation() {
        #expect(BrainServiceFolders.abbreviated(path: "/Volumes/Drive/notes", homeDirectory: home) == "/Volumes/Drive/notes")
        #expect(BrainServiceFolders.abbreviated(path: "/Users/someone2/notes", homeDirectory: home) == "/Users/someone2/notes")
        #expect(BrainServiceFolders.abbreviated(path: "/Users/someone", homeDirectory: home) == "~")
    }

    @Test("no summary yet and nothing running shows no line")
    func noSummaryYet() {
        let status = BrainServiceStatus.make(
            hasFolders: true, isRefreshing: false, lastSummary: nil, firstUnreadableFolderPath: nil, homeDirectory: home)
        #expect(status == nil)
    }
}

@Suite("Brain service folders")
struct BrainServiceFoldersTests {
    @Test("a tilde expands to the home folder and a relative-looking entry is made absolute")
    func expand() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let urls = BrainServiceFolders.expand(paths: ["~/notes", "/abs/path/", "  "], homeDirectory: home)
        #expect(urls.map(\.path) == ["/Users/someone/notes", "/abs/path"])
    }

    @Test("the first missing or unreadable folder is named, readable ones are not")
    func firstUnreadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("svc-folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        let aFile = root.appendingPathComponent("file.txt")
        try "x".write(to: aFile, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing")
        #expect(BrainServiceFolders.firstUnreadable([good]) == nil)
        #expect(BrainServiceFolders.firstUnreadable([good, missing, aFile])?.path == missing.path)
        #expect(BrainServiceFolders.firstUnreadable([aFile])?.path == aFile.path)
        #expect(BrainServiceFolders.readable([good, missing, aFile]).map(\.path) == [good.path])
    }

    @Test("the root folder and the home folder are refused as search folders, with a reason")
    func rootAndHomeAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("svc-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let notes = home.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let homeAlias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: homeAlias, withDestinationURL: home)

        #expect(BrainServiceFolders.refusalReason(for: URL(fileURLWithPath: "/"), homeDirectory: home) != nil)
        #expect(BrainServiceFolders.refusalReason(for: home, homeDirectory: home) != nil)
        #expect(BrainServiceFolders.refusalReason(for: home.appendingPathComponent("notes/.."), homeDirectory: home) != nil)
        #expect(BrainServiceFolders.refusalReason(for: homeAlias, homeDirectory: home) != nil)
        #expect(BrainServiceFolders.refusalReason(for: URL(fileURLWithPath: home.path + "/"), homeDirectory: home) != nil)
        #expect(BrainServiceFolders.refusalReason(for: notes, homeDirectory: home) == nil)
        let expanded = BrainServiceFolders.expand(paths: ["~", "/", "~/notes"], homeDirectory: home)
        #expect(BrainServiceFolders.allowed(expanded, homeDirectory: home).map(\.path) == [notes.path])
    }

    @Test("isReadableFolder is false for the root folder, so the status line names it")
    func rootIsNotReadableFolder() {
        #expect(!BrainServiceFolders.isReadableFolder(URL(fileURLWithPath: "/")))
        #expect(!BrainServiceFolders.isReadableFolder(URL(fileURLWithPath: NSHomeDirectory())))
        #expect(BrainServiceFolders.firstUnreadable([URL(fileURLWithPath: "/")])?.path == "/")
    }
}
