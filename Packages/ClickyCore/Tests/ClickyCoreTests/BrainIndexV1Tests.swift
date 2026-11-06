import Foundation
import Testing

@testable import ClickyCore

/// Fix wave 3, group V1: case spelling of the search folders through the index and the helper, and stale rows that
/// outnumber every fixed over-fetch.
@Suite("Brain index, wave 3 boundary")
struct BrainIndexV1Tests {
    private func volumeIsCaseInsensitive(_ tree: BrainTempTree) -> Bool {
        (try? tree.write("CaseProbe.txt", "x")) != nil && FileManager.default.fileExists(atPath: tree.url("caseprobe.txt").path)
    }

    private func makeCaseTree() throws -> (tree: BrainTempTree, index: BrainIndex, folder: URL) {
        let tree = try BrainTempTree(name: "brain-v1case")
        let folder = try tree.folder("cs")
        try tree.write("cs/Notes/A.md", "# Okapi census\n\n## Okapi census\n\nThe okapi census is on Tuesday.\n")
        for fillerNumber in 0..<100 { try tree.write("cs/f\(fillerNumber).md", "# Garden \(fillerNumber)\n\nTomato bed \(fillerNumber) needs compost.\n") }
        let index = try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite"))
        try index.update(searchFolders: [folder])
        return (tree, index, folder)
    }

    @Test func passagesSurviveAFolderSpeltInAnotherCase() throws {
        let (tree, index, _) = try makeCaseTree()
        defer { tree.cleanUp() }
        guard volumeIsCaseInsensitive(tree) else { print("skipped: case-sensitive temp volume"); return }
        let passages = try index.passages(
            forQuestion: "okapi census", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [tree.url("CS")])
        #expect(passages.map { ($0.path as NSString).lastPathComponent } == ["A.md"])
    }

    @Test func theHelperSearchSurvivesAFolderSpeltInAnotherCase() throws {
        let (tree, index, _) = try makeCaseTree()
        defer { tree.cleanUp() }
        guard volumeIsCaseInsensitive(tree) else { print("skipped: case-sensitive temp volume"); return }
        let backend = BrainServiceHelperBackend(
            indexDatabaseURL: index.databaseURL, launchFolders: [tree.url("CS")],
            folderListFileURL: BrainServiceFolderListFile.url(besideIndexDatabase: index.databaseURL))
        let hits = try backend.search(query: "okapi census", limit: 5)
        #expect(hits.map { ($0.path as NSString).lastPathComponent } == ["A.md"])
    }

    // MARK: V1.2

    /// 200 strong chunks in the removed folder `r`, 3 weaker matching ones in the kept folder `k`.
    private func makeStaleIndex() throws -> (tree: BrainTempTree, index: BrainIndex, removed: URL, kept: URL) {
        let tree = try BrainTempTree(name: "brain-v1stale")
        let removed = try tree.folder("r"), kept = try tree.folder("k")
        for noteNumber in 0..<200 {
            try tree.write("r/n\(noteNumber).md", "# Narwhal migration \(noteNumber)\n\n## Narwhal migration\n\nnarwhal migration narwhal migration narwhal migration narwhal migration\n")
        }
        for keptNumber in 0..<3 {
            try tree.write("k/one\(keptNumber).md", "# Narwhal migration harbour log \(keptNumber)\n\n## Narwhal sightings\n\nA narwhal migration was seen near the harbour \(keptNumber).\n")
        }
        for fillerNumber in 0..<1500 { try tree.write("k/filler\(fillerNumber).md", "# Garden \(fillerNumber)\n\nTomato bed \(fillerNumber) needs compost.\n") }
        let index = try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite"))
        try index.update(searchFolders: [removed, kept])
        let strongest = try index.search(query: "narwhal migration", limit: 100)
        #expect(strongest.count == 100 && strongest.allSatisfy { $0.path.contains("/r/") }, "premise: r fills the top 100")
        return (tree, index, removed, kept)
    }

    @Test func theHelperSearchPagesPastTwoHundredStaleRows() throws {
        let (tree, index, removed, kept) = try makeStaleIndex()
        defer { tree.cleanUp() }
        let listFile = BrainServiceFolderListFile.url(besideIndexDatabase: index.databaseURL)
        try BrainServiceFolderListFile.write(folders: [kept], to: listFile)
        let backend = BrainServiceHelperBackend(
            indexDatabaseURL: index.databaseURL, launchFolders: [removed, kept], folderListFileURL: listFile)
        let hits = try backend.search(query: "narwhal migration", limit: 5)
        #expect(hits.count == 3, "got \(hits.map { ($0.path as NSString).lastPathComponent })")
        #expect(hits.allSatisfy { $0.path.contains("/k/") })
    }

    @Test func passagesPagePastTwoHundredStaleRows() throws {
        let (tree, index, _, kept) = try makeStaleIndex()
        defer { tree.cleanUp() }
        let passages = try index.passages(
            forQuestion: "narwhal migration", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [kept], scoreFloorOverride: 0)
        #expect(!passages.isEmpty && passages.allSatisfy { $0.path.contains("/k/") })
    }

    @Test func withNothingRemovedTheTopFiveAreTheSameAsTheRankedRows() throws {
        let tree = try BrainTempTree(name: "brain-v1same")
        defer { tree.cleanUp() }
        let kept = try tree.folder("k")
        for noteNumber in 0..<40 { try tree.write("k/n\(noteNumber).md", "# Wombat \(noteNumber)\n\n" + String(repeating: "wombat ", count: noteNumber % 7 + 1) + "notes\n") }
        let index = try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite"))
        try index.update(searchFolders: [kept])
        let backend = BrainServiceHelperBackend(
            indexDatabaseURL: index.databaseURL, launchFolders: [kept],
            folderListFileURL: BrainServiceFolderListFile.url(besideIndexDatabase: index.databaseURL))
        let expected = try index.search(query: "wombat", limit: 5).map(\.path)
        #expect(try backend.search(query: "wombat", limit: 5).map(\.path) == expected)
    }
}
