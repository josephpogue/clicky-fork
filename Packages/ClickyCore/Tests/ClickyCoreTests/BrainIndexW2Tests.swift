import Foundation
import Testing

@testable import ClickyCore

/// Fix wave 2 for the index, the folder list file and the helper's tools.
@Suite("Brain index, wave 2")
struct BrainIndexW2Tests {
    // MARK: finding 6: the open refuses a symlink anywhere in the path

    @Test func aParentFolderSwappedForASymlinkIsNotFollowed() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        try tree.write("real/note.md", "# Note\n\nThe okapi census is on Tuesday.\n")
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("real/note.md").path) != nil)
        // The walker checked `inside/note.md`, then `inside` became a link to another folder before the open.
        try FileManager.default.createSymbolicLink(at: tree.url("inside"), withDestinationURL: tree.url("real"))
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("inside/note.md").path) == nil)
    }

    // MARK: finding 3: a removed folder's rows cannot crowd out a kept folder's hits

    /// Folder `gone` holds 30 notes (more than the 20 candidates, fewer than the 100 fetched) that outscore the one note in `kept`.
    private func makeCrowdedIndex(_ tree: BrainTempTree) throws -> (index: BrainIndex, gone: URL, kept: URL) {
        let gone = try tree.folder("gone"), kept = try tree.folder("kept")
        for noteNumber in 0..<30 {
            try tree.write(
                "gone/n\(noteNumber).md",
                "# Narwhal migration plan \(noteNumber)\n\n## Narwhal migration\n\nnarwhal migration narwhal migration narwhal migration narwhal migration narwhal migration\n")
        }
        try tree.write("kept/one.md", "# Narwhal migration harbour log\n\n## Narwhal migration sightings\n\nA narwhal migration was seen near the harbour once.\n")
        // Unrelated notes, so the two words are rare in the corpus and a real hit clears the score floor.
        for fillerNumber in 0..<200 {
            try tree.write("kept/filler\(fillerNumber).md", "# Garden \(fillerNumber)\n\nTomato bed number \(fillerNumber) needs water and compost.\n")
        }
        let index = try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite"))
        try index.update(searchFolders: [gone, kept])
        let strongest = try index.search(query: "narwhal migration", limit: 20)
        #expect(strongest.allSatisfy { $0.path.contains("/gone/") }, "the test's premise: the removed folder fills the top 20")
        return (index, gone, kept)
    }

    @Test func passagesOfAKeptFolderSurviveARemovedFoldersCrowd() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let setup = try makeCrowdedIndex(tree)
        let passages = try setup.index.passages(
            forQuestion: "narwhal migration", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [setup.kept])
        #expect(passages.map { ($0.path as NSString).lastPathComponent } == ["one.md"])
    }

    @Test func theHelpersSearchOfAKeptFolderSurvivesARemovedFoldersCrowd() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let setup = try makeCrowdedIndex(tree)
        let listFile = BrainServiceFolderListFile.url(besideIndexDatabase: setup.index.databaseURL)
        try BrainServiceFolderListFile.write(folders: [setup.kept], to: listFile)
        let backend = BrainServiceHelperBackend(
            indexDatabaseURL: setup.index.databaseURL, launchFolders: [setup.gone, setup.kept], folderListFileURL: listFile)
        let hits = try backend.search(query: "narwhal migration", limit: 10)
        #expect(hits.map { ($0.path as NSString).lastPathComponent } == ["one.md"])
    }

    @Test func theHelperStillReturnsAtMostTheAskedLimit() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let kept = try tree.folder("kept")
        for noteNumber in 0..<12 { try tree.write("kept/n\(noteNumber).md", "# Wombat \(noteNumber)\n\nwombat notes\n") }
        let index = try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite"))
        try index.update(searchFolders: [kept])
        let backend = BrainServiceHelperBackend(
            indexDatabaseURL: index.databaseURL, launchFolders: [kept],
            folderListFileURL: BrainServiceFolderListFile.url(besideIndexDatabase: index.databaseURL))
        #expect(try backend.search(query: "wombat", limit: 3).count == 3)
    }
}

@Suite("Brain folder list file, wave 2")
struct BrainServiceFolderListFileW2Tests {
    // MARK: finding 4: one rule for what a session may use

    @Test func foldersInBothListsAreTheOnesTheHelperServes() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta"), gamma = try tree.folder("gamma")
        // The session started with alpha and beta; Settings now has beta and gamma (gamma added mid-session).
        #expect(BrainServiceFolderListFile.foldersInBoth(startList: [alpha, beta], currentList: [beta, gamma]) == [beta])
        #expect(BrainServiceFolderListFile.foldersInBoth(startList: [], currentList: [beta]).isEmpty)
    }

    // MARK: finding 5: a failed write is retried once, then the stale file goes and attaching stops

    private struct DiskFull: Error {}

    private final class Recorder: @unchecked Sendable {
        var writeAttempts = 0
        var removals = 0
        var logged: [String] = []
    }

    @Test func aWriteThatFailsOnceIsRetriedAndSucceeds() {
        let recorder = Recorder()
        let succeeded = BrainServiceFolderListFile.writeRetryingOnce(
            write: { recorder.writeAttempts += 1; if recorder.writeAttempts == 1 { throw DiskFull() } },
            removeStaleFile: { recorder.removals += 1 }, log: { recorder.logged.append($0) })
        #expect(succeeded)
        #expect(recorder.writeAttempts == 2)
        #expect(recorder.removals == 0)
        #expect(recorder.logged.isEmpty)
    }

    @Test func aWriteThatFailsTwiceIsLoggedTheStaleFileIsRemovedAndItReportsFailure() {
        let recorder = Recorder()
        let succeeded = BrainServiceFolderListFile.writeRetryingOnce(
            write: { recorder.writeAttempts += 1; throw DiskFull() },
            removeStaleFile: { recorder.removals += 1 }, log: { recorder.logged.append($0) })
        #expect(!succeeded)
        #expect(recorder.writeAttempts == 2)
        #expect(recorder.removals == 1)
        #expect(recorder.logged.count == 1)
    }

    @Test func aFailedRemovalIsLoggedToo() {
        let recorder = Recorder()
        let succeeded = BrainServiceFolderListFile.writeRetryingOnce(
            write: { throw DiskFull() }, removeStaleFile: { throw DiskFull() }, log: { recorder.logged.append($0) })
        #expect(!succeeded)
        #expect(recorder.logged.count == 2)
    }

    @Test func theRealWriteFailsWhenTheFolderCannotBeMadeAndRemovesNothingItDoesNotHave() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        try tree.write("blocker", "a file where a folder should be")
        let listFile = tree.url("blocker/folders.json")
        var logged: [String] = []
        let succeeded = BrainServiceFolderListFile.writeRetryingOnce(
            folders: [tree.root], indexedFolders: [], to: listFile, log: { logged.append($0) })
        #expect(!succeeded)
        #expect(!logged.isEmpty)
    }

    // MARK: finding 2: which folders the last completed update covered

    @Test func theCoveredFoldersRoundTripAndAnOlderFileLacksThem() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let listFile = tree.url("folders.json")
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha], to: listFile)
        let listing = BrainServiceFolderListFile.readListing(from: listFile)
        #expect(listing?.folders == [alpha.path, beta.path])
        #expect(listing?.indexedFolders == [alpha.path])
        #expect(BrainServiceFolderListFile.read(from: listFile) == [alpha.path, beta.path])
        // The file as the first wave wrote it: a bare list.
        try "[\"\(alpha.path)\"]".write(to: listFile, atomically: true, encoding: .utf8)
        #expect(BrainServiceFolderListFile.readListing(from: listFile)?.folders == [alpha.path])
        #expect(BrainServiceFolderListFile.readListing(from: listFile)?.indexedFolders == nil)
        #expect(BrainServiceFolderListFile.read(from: listFile) == [alpha.path])
    }

    @Test func foldersStillBeingIndexedForEachState() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let listFile = tree.url("folders.json")
        func pending(launch: [URL]) -> [URL] {
            BrainServiceFolderListFile.foldersStillBeingIndexed(launchFolders: launch, listFileURL: listFile)
        }
        // No file at all: nothing is known, nothing is claimed.
        #expect(pending(launch: [alpha]).isEmpty)
        // The first build is running: the list is written, nothing is covered yet.
        try BrainServiceFolderListFile.write(folders: [alpha], indexedFolders: [], to: listFile)
        #expect(pending(launch: [alpha]) == [alpha])
        // A folder added mid-build: alpha is covered, beta is not.
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha], to: listFile)
        #expect(pending(launch: [alpha, beta]) == [beta])
        // A folder added after the session started is not served at all, so it is not "being indexed" for this session.
        #expect(pending(launch: [alpha]).isEmpty)
        // The build is done.
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha, beta], to: listFile)
        #expect(pending(launch: [alpha, beta]).isEmpty)
        // A file from before this change has no covered list: no claim.
        try BrainServiceFolderListFile.write(folders: [alpha, beta], to: listFile)
        #expect(pending(launch: [alpha, beta]).isEmpty)
        // A removed folder is not pending even if it was never covered.
        try BrainServiceFolderListFile.write(folders: [alpha], indexedFolders: [alpha], to: listFile)
        #expect(pending(launch: [alpha, beta]).isEmpty)
    }

    // MARK: the helper says so instead of "No notes matched"

    private func makeBackend(_ tree: BrainTempTree, launch: [URL]) throws -> (backend: BrainServiceHelperBackend, listFile: URL) {
        let database = tree.url("brain-index/index.sqlite")
        let listFile = BrainServiceFolderListFile.url(besideIndexDatabase: database)
        return (BrainServiceHelperBackend(indexDatabaseURL: database, launchFolders: launch, folderListFileURL: listFile), listFile)
    }

    @Test func aSearchWithNoIndexYetAndAFolderBeingIndexedSaysSoInsteadOfFailing() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha")
        let (backend, listFile) = try makeBackend(tree, launch: [alpha])
        try BrainServiceFolderListFile.write(folders: [alpha], indexedFolders: [], to: listFile)
        let result = try backend.search(query: "quokka", limit: 5)
        #expect(result.count == 1)
        #expect(result.first?.text.contains("still being indexed") == true)
        #expect(result.first?.text.contains("alpha") == true)
    }

    @Test func aSearchWithNoHitsInAFolderBeingIndexedReturnsTheNoticeAlone() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        try tree.write("alpha/a.md", "# Alpha\n\nThe quokka plan lives in alpha.\n")
        try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite")).update(searchFolders: [alpha])
        let (backend, listFile) = try makeBackend(tree, launch: [alpha, beta])
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha], to: listFile)
        let result = try backend.search(query: "wombat", limit: 5)
        #expect(result.count == 1)
        #expect(result.first?.text.contains("beta") == true)
        #expect(result.first?.text.contains("still being indexed") == true)
    }

    @Test func aSearchWithHitsAndAFolderBeingIndexedLeadsWithTheNotice() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        try tree.write("alpha/a.md", "# Alpha\n\nThe quokka plan lives in alpha.\n")
        try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite")).update(searchFolders: [alpha])
        let (backend, listFile) = try makeBackend(tree, launch: [alpha, beta])
        try BrainServiceFolderListFile.write(folders: [alpha, beta], indexedFolders: [alpha], to: listFile)
        let result = try backend.search(query: "quokka", limit: 5)
        #expect(result.count == 2)
        #expect(result.first?.text.contains("still being indexed") == true)
        #expect((result.last?.path as NSString?)?.lastPathComponent == "a.md")
    }

    @Test func aFinishedBuildOrAnOlderFileAddsNothing() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha")
        try tree.write("alpha/a.md", "# Alpha\n\nThe quokka plan lives in alpha.\n")
        try BrainIndex(databaseURL: tree.url("brain-index/index.sqlite")).update(searchFolders: [alpha])
        let (backend, listFile) = try makeBackend(tree, launch: [alpha])
        try BrainServiceFolderListFile.write(folders: [alpha], indexedFolders: [alpha], to: listFile)
        #expect(try backend.search(query: "quokka", limit: 5).count == 1)
        #expect(try backend.search(query: "wombat", limit: 5).isEmpty)
        try BrainServiceFolderListFile.write(folders: [alpha], to: listFile)
        #expect(try backend.search(query: "quokka", limit: 5).count == 1)
        #expect(try backend.search(query: "wombat", limit: 5).isEmpty)
    }
}
