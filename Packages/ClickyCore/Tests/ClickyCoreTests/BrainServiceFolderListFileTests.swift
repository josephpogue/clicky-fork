import Foundation
import Testing

@testable import ClickyCore

@Suite("Brain folder list file and helper backend")
struct BrainServiceFolderListFileTests {
    @Test func roundTripsAndIntersectsWithTheLaunchList() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let listFile = tree.url("brain-index/folders.json")
        try BrainServiceFolderListFile.write(folders: [alpha], to: listFile)
        #expect(BrainServiceFolderListFile.read(from: listFile) == [alpha.path])
        #expect(BrainServiceFolderListFile.effectiveFolders(launchFolders: [alpha, beta], listFileURL: listFile) == [alpha])
    }

    @Test func anAdditionOnlyCountsFromTheNextSession() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        let listFile = tree.url("folders.json")
        try BrainServiceFolderListFile.write(folders: [alpha, beta], to: listFile)
        #expect(BrainServiceFolderListFile.effectiveFolders(launchFolders: [alpha], listFileURL: listFile) == [alpha])
    }

    @Test func removedThenReAddedBeforeTheNextSessionIsBackInTheLaunchList() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha")
        let listFile = tree.url("folders.json")
        try BrainServiceFolderListFile.write(folders: [], to: listFile)
        try BrainServiceFolderListFile.write(folders: [alpha], to: listFile)
        // The next session launches with the list as it is now.
        #expect(BrainServiceFolderListFile.effectiveFolders(launchFolders: [alpha], listFileURL: listFile) == [alpha])
    }

    @Test func missingOrCorruptFileFallsBackToTheLaunchList() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha")
        let listFile = tree.url("folders.json")
        #expect(BrainServiceFolderListFile.effectiveFolders(launchFolders: [alpha], listFileURL: listFile) == [alpha])
        for corrupt in ["", "not json", "{\"a\":1}", "[1,2]", "[\"/x\""] {
            try corrupt.write(to: listFile, atomically: true, encoding: .utf8)
            #expect(
                BrainServiceFolderListFile.effectiveFolders(launchFolders: [alpha], listFileURL: listFile) == [alpha],
                "\(corrupt)")
        }
    }

    @Test func emptyListMeansNoFolders() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        let alpha = try tree.folder("alpha")
        let listFile = tree.url("folders.json")
        try BrainServiceFolderListFile.write(folders: [], to: listFile)
        #expect(BrainServiceFolderListFile.effectiveFolders(launchFolders: [alpha], listFileURL: listFile).isEmpty)
    }

    @Test func helperArgumentsNameTheFoldersFileBesideTheIndex() {
        let database = URL(fileURLWithPath: "/data/brain-index/index.sqlite")
        let arguments = BrainToolServer.helperArguments(
            indexDatabaseURL: database, searchFolders: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])
        #expect(arguments == [
            "--index", "/data/brain-index/index.sqlite", "--folders-file", "/data/brain-index/folders.json",
            "--folder", "/a", "--folder", "/b",
        ])
    }

    // MARK: the helper's tools follow the list

    private struct Setup {
        let tree: BrainTempTree
        let alpha: URL
        let beta: URL
        let database: URL
        let listFile: URL
        let backend: BrainServiceHelperBackend
    }

    private func makeSetup() throws -> Setup {
        let tree = try BrainTempTree()
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        try tree.write("alpha/a.md", "# Alpha\n\n## Quokka\n\nThe quokka plan lives in alpha.\n")
        try tree.write("beta/b.md", "# Beta\n\n## Wombat\n\nThe wombat plan lives in beta.\n")
        let database = tree.url("brain-index/index.sqlite")
        let index = try BrainIndex(databaseURL: database)
        try index.update(searchFolders: [alpha, beta])
        let listFile = BrainServiceFolderListFile.url(besideIndexDatabase: database)
        let backend = BrainServiceHelperBackend(
            indexDatabaseURL: database, launchFolders: [alpha, beta], folderListFileURL: listFile)
        return Setup(tree: tree, alpha: alpha, beta: beta, database: database, listFile: listFile, backend: backend)
    }

    @Test func aFolderRemovedMidSessionIsNeitherSearchableNorReadable() throws {
        let setup = try makeSetup()
        defer { setup.tree.cleanUp() }
        // Before the removal both are served.
        #expect(try setup.backend.search(query: "wombat", limit: 5).count == 1)
        try BrainServiceFolderListFile.write(folders: [setup.alpha], to: setup.listFile)
        // The index still holds beta's rows (the rebuild has not run), yet the very next call refuses them.
        #expect(try setup.backend.search(query: "wombat", limit: 5).isEmpty)
        #expect(try setup.backend.search(query: "quokka", limit: 5).count == 1)
        #expect(throws: BrainFileRefusal.outsideSearchFolders) {
            try setup.backend.readFile(path: setup.beta.appendingPathComponent("b.md").path, startLine: 1, lineCount: 5)
        }
        #expect(try setup.backend.readFile(
            path: setup.alpha.appendingPathComponent("a.md").path, startLine: 1, lineCount: 5).lines.joined(separator: "\n").contains("quokka"))
    }

    @Test func allFoldersRemovedMeansNothingIsFoundAndEveryReadIsRefused() throws {
        let setup = try makeSetup()
        defer { setup.tree.cleanUp() }
        try BrainServiceFolderListFile.write(folders: [], to: setup.listFile)
        #expect(try setup.backend.search(query: "quokka", limit: 5).isEmpty)
        #expect(throws: BrainFileRefusal.outsideSearchFolders) {
            try setup.backend.readFile(path: setup.alpha.appendingPathComponent("a.md").path, startLine: 1, lineCount: 5)
        }
    }

    @Test func aCorruptFileKeepsTheLaunchList() throws {
        let setup = try makeSetup()
        defer { setup.tree.cleanUp() }
        try "{ broken".write(to: setup.listFile, atomically: true, encoding: .utf8)
        #expect(try setup.backend.search(query: "wombat", limit: 5).count == 1)
    }
}
