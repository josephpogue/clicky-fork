import Foundation
import Testing

@testable import ClickyCore

/// A stand-in for the service's lock-guarded state: what Settings lists now and what the last update covered.
private final class FakeFolderState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [URL]
    private var covered: [URL]?

    init(current: [URL], covered: [URL]?) {
        self.current = current
        self.covered = covered
    }

    func setCurrent(_ folders: [URL]) { lock.lock(); current = folders; lock.unlock() }
    func readCurrent() -> [URL] { lock.lock(); defer { lock.unlock() }; return current }
    func readCovered() -> [URL]? { lock.lock(); defer { lock.unlock() }; return covered }
}

@Suite("Brain folder list writer")
struct BrainServiceFolderListWriterTests {
    private func makeWriter(
        tree: BrainTempTree, state: FakeFolderState, listFile: URL? = nil
    ) -> (BrainServiceFolderListWriter, URL) {
        let listFileURL = listFile ?? tree.url("brain-index/folders.json")
        let writer = BrainServiceFolderListWriter(
            listFileURL: listFileURL, indexDatabaseURL: tree.url("brain-index/index.sqlite"),
            currentFolders: { state.readCurrent() }, coveredFolders: { state.readCovered() }, log: { _ in })
        return (writer, listFileURL)
    }

    @Test func aLateRunWriteDoesNotBringARemovedFolderBack() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        // The run snapshotted [alpha, beta] and covered both; Settings then removed beta.
        let state = FakeFolderState(current: [alpha, beta], covered: [alpha, beta])
        let (writer, listFile) = makeWriter(tree: tree, state: state)
        state.setCurrent([alpha])
        writer.writeNewest()  // Settings
        writer.writeNewest()  // the run's write, landing last
        let listing = try #require(BrainServiceFolderListFile.readListing(from: listFile))
        #expect(listing.folders == [alpha.path])
        #expect(listing.indexedFolders == [alpha.path])
    }

    @Test func indexedFoldersNeverListsAFolderOutsideFolders() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let state = FakeFolderState(current: [alpha], covered: [alpha, beta])
        let (writer, listFile) = makeWriter(tree: tree, state: state)
        writer.writeNewest()
        let listing = try #require(BrainServiceFolderListFile.readListing(from: listFile))
        #expect(listing.indexedFolders == [alpha.path])
    }

    @Test func manyConcurrentWritesLeaveValidJsonWithTheNewestList() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let state = FakeFolderState(current: [alpha, beta], covered: [alpha, beta])
        let (writer, listFile) = makeWriter(tree: tree, state: state)
        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            // Even iterations are "run" writes, odd ones are "Settings" writes; both flip the list first.
            state.setCurrent(iteration % 3 == 0 ? [alpha] : [alpha, beta])
            writer.writeNewest()
        }
        state.setCurrent([alpha])
        writer.writeNewest()
        let listing = try #require(BrainServiceFolderListFile.readListing(from: listFile))
        #expect(listing.folders == [alpha.path])
        #expect(listing.indexedFolders == [alpha.path])
        #expect(writer.fileIsCurrent)
    }

    @Test func aFailedWriteLeavesTheFileNotCurrentAndASuccessRestoresIt() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha")
        // The list file's folder is a regular file, so creating it fails.
        let blocker = tree.url("blocker")
        try Data("x".utf8).write(to: blocker)
        let state = FakeFolderState(current: [alpha], covered: [alpha])
        let (writer, _) = makeWriter(tree: tree, state: state, listFile: blocker.appendingPathComponent("folders.json"))
        writer.writeNewest()
        #expect(!writer.fileIsCurrent)

        let (healthyWriter, _) = makeWriter(tree: tree, state: state)
        healthyWriter.writeNewest()
        #expect(healthyWriter.fileIsCurrent)
    }

    @Test func withNoFoldersAndNoIndexFolderNothingIsCreated() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let state = FakeFolderState(current: [], covered: nil)
        let (writer, listFile) = makeWriter(tree: tree, state: state)
        writer.writeNewest()
        #expect(!FileManager.default.fileExists(atPath: listFile.path))
    }

    @Test func unknownCoverageIsReadBackFromTheFileOnlyWhenTheIndexExists() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let listFile = tree.url("brain-index/folders.json")
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha], to: listFile)
        let state = FakeFolderState(current: [alpha, beta], covered: nil)
        let (writer, _) = makeWriter(tree: tree, state: state)
        writer.writeNewest()  // no index database on disk: nothing is covered
        #expect(BrainServiceFolderListFile.readListing(from: listFile)?.indexedFolders == [])
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha], to: listFile)
        try Data().write(to: tree.url("brain-index/index.sqlite"))
        writer.writeNewest()  // an index exists: the file's coverage counts
        #expect(BrainServiceFolderListFile.readListing(from: listFile)?.indexedFolders == [alpha.path])
    }
}
