import Foundation
import Testing

@testable import ClickyCore

/// A temporary notes folder built from strings. Never reads the real brain.
private struct BrainFixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-fixture-\(UUID().uuidString)")
        databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("brain-index-\(UUID().uuidString)/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeFolder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    /// The fixture from the slice brief.
    static func standard() throws -> BrainFixture {
        let fixture = try BrainFixture()
        try fixture.write(
            "Wiki/Projects/demo-server.md",
            "# Demo server\n\n## Ports\n\nThe demo server listens on port 4417 behind the lab proxy.\n")
        try fixture.write(
            "Wiki/Projects/clicky-fork.md",
            "# Clicky Fork\n\n## Build\n\nRelease builds go through scripts/build-app.sh.\n")
        try fixture.makeFolder("projects/clicky-fork/.git")
        try fixture.write("projects/clicky-fork/docs/notes.md", "## Build\n\nRun make test before a PR.\n")
        try fixture.makeFolder("projects/espn-fantasy/.git")
        try fixture.write("projects/espn-fantasy/README.md", "# ESPN fantasy\n\nLeague 420987259 lineup moves.\n")
        try fixture.write("projects/clicky-fork-worktrees/x/docs/notes.md", "## Build\n\nport 4417\n")
        try fixture.write("node_modules/a/README.md", "# Package\n\nport 4417\n")
        try fixture.write(".env", "SECRET=1\n")
        try fixture.write("big.md", "# Big\n\n" + String(repeating: "port 4417 filler words here\n", count: 30_000))
        try fixture.write("image.png", "not really a png")
        return fixture
    }

    /// Everyday notes whose words come from a small shared vocabulary, so common words have the low rarity they
    /// have in a real set of notes. Deterministic. Without them a four-note fixture gives every word a rarity near zero.
    func addFillerNotes(count: Int = 300) throws {
        let vocabulary = [
            "save", "button", "error", "mean", "click", "window", "open", "file", "menu", "screen", "text", "name", "list",
            "item", "page", "view", "form", "field", "user", "time", "day", "note", "plan", "work", "call", "email", "send",
            "check", "update", "change", "review", "meeting", "task", "team", "budget", "report", "draft", "share", "link",
            "folder", "setting", "option", "tab", "icon", "panel", "dialog", "message", "alert", "code", "test", "run", "port",
            "server", "lab", "deploy", "script", "fix", "bug", "issue", "ticket",
        ]
        var seed: UInt64 = 42
        func nextNumber() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        for noteNumber in 0..<count {
            var text = "# Topic \(noteNumber)\n\n"
            for partNumber in 0..<3 {
                text += "## Part \(partNumber)\n\n"
                text += (0..<25).map { _ in vocabulary[nextNumber() % vocabulary.count] }.joined(separator: " ") + "\n\n"
            }
            try write("filler/f\(noteNumber).md", text)
        }
    }

    func paths(_ passages: [BrainPassage]) -> [String] { passages.map(\.path) }
}

@Suite("BrainIndex update")
struct BrainIndexUpdateTests {
    @Test func indexesOnlyAllowedFiles() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        let summary = try index.update(searchFolders: [fixture.root])
        // demo-server, clicky-fork page, notes, README
        #expect(summary.filesIndexed == 4)
        #expect(summary.filesUnchanged == 0)
        let everything = try index.search(query: "port build league fantasy secret package", limit: 50)
        let everyPath = Set(everything.map(\.path))
        #expect(everyPath.count == 4)
        #expect(!everyPath.contains { $0.contains("worktrees") || $0.contains("node_modules") || $0.hasSuffix("big.md") })
    }

    @Test func secondUpdateChangesNothingAndTouchingOneFileReindexesOne() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        let first = try index.update(searchFolders: [fixture.root])
        let second = try index.update(searchFolders: [fixture.root])
        #expect(second.filesIndexed == 0)
        #expect(second.filesUnchanged == 4)
        #expect(second.chunkCount == first.chunkCount)

        let notes = fixture.root.appendingPathComponent("projects/clicky-fork/docs/notes.md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: notes.path)
        let third = try index.update(searchFolders: [fixture.root])
        #expect(third.filesIndexed == 1)
        #expect(third.filesUnchanged == 3)
        #expect(third.chunkCount == first.chunkCount)
    }

    @Test func changedContentReplacesOldChunks() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        try fixture.write("Wiki/Projects/demo-server.md", "# Demo server\n\n## Ports\n\nNow it listens on port 9001 only.\n")
        let summary = try index.update(searchFolders: [fixture.root])
        #expect(summary.filesIndexed == 1)
        #expect(try index.search(query: "4417", limit: 5).isEmpty)
        #expect(try index.search(query: "9001", limit: 5).count == 1)
    }

    @Test func deletedFileAndFolderLeftOutAreRemoved() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Wiki/Projects/demo-server.md"))
        let afterDelete = try index.update(searchFolders: [fixture.root])
        #expect(afterDelete.filesRemoved == 1)
        #expect(try index.search(query: "4417", limit: 5).isEmpty)

        // A folder dropped from the search list takes its files with it.
        let afterDrop = try index.update(searchFolders: [fixture.root.appendingPathComponent("Wiki")])
        #expect(afterDrop.filesRemoved == 2)
        #expect(try index.search(query: "league", limit: 5).isEmpty)
        #expect(try index.search(query: "release", limit: 5).count == 1)
    }

    @Test func symlinksAreNotFollowedOutOfTheSearchFolders() throws {
        let fixture = try BrainFixture()
        let outside = try BrainFixture()
        defer { fixture.cleanUp(); outside.cleanUp() }
        try fixture.write("inside.md", "# Inside\n\nkeepme zebra\n")
        try outside.write("outside.md", "# Outside\n\nsecretish zebra\n")
        try outside.write("folder/deep.md", "# Deep\n\nzebra deep\n")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked-file.md"), withDestinationURL: outside.root.appendingPathComponent("outside.md"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked-folder"), withDestinationURL: outside.root.appendingPathComponent("folder"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("alias.md"), withDestinationURL: fixture.root.appendingPathComponent("inside.md"))
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        let summary = try index.update(searchFolders: [fixture.root])
        #expect(summary.filesIndexed == 1)
        let found = try index.search(query: "zebra", limit: 10)
        #expect(found.count == 1)
        #expect(found.first?.path.hasSuffix("/inside.md") == true)
    }

    @Test func repositoryNamesAndFileNameLookup() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        #expect(try index.repositoryProjectNames() == ["clicky-fork", "espn-fantasy"])
        let readmes = try index.indexedFiles(named: "README.md")
        #expect(readmes.count == 1)
        #expect(readmes.first?.hasSuffix("projects/espn-fantasy/README.md") == true)
        #expect(try index.indexedFiles(named: "readme.MD") == readmes)
    }

    @Test func schemaVersionChangeRebuilds() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        do {
            let index = try BrainIndex(databaseURL: fixture.databaseURL)
            try index.update(searchFolders: [fixture.root])
        }
        let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: false)
        try database.execute("UPDATE meta SET value = '0' WHERE key = 'schema_version'")
        let reopened = try BrainIndex(databaseURL: fixture.databaseURL)
        let summary = try reopened.update(searchFolders: [fixture.root])
        #expect(summary.filesIndexed == 4)
        #expect(summary.filesUnchanged == 0)
    }

    @Test func readOnlyNeedsABuiltIndex() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        #expect(throws: BrainIndexError.self) { try BrainIndex(databaseURL: fixture.databaseURL, readOnly: true) }
        let writer = try BrainIndex(databaseURL: fixture.databaseURL)
        try writer.update(searchFolders: [fixture.root])
        let reader = try BrainIndex(databaseURL: fixture.databaseURL, readOnly: true)
        #expect(try reader.search(query: "demo server port", limit: 3).count >= 1)
    }
}

@Suite("BrainIndex search")
struct BrainIndexSearchTests {
    @Test func spokenQuestionFindsTheRightHeading() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let results = try index.search(query: "what port does the demo server use", limit: 5)
        let top = try #require(results.first)
        #expect(top.path.hasSuffix("demo-server.md"))
        #expect(top.heading == "Ports")
        #expect(top.startLine == 3)
        #expect(top.endLine == 5)
        #expect(top.text.contains("4417"))
        #expect(top.score > 0)
    }

    @Test func headingMatchOutranksBodyOnlyMention() throws {
        let fixture = try BrainFixture()
        defer { fixture.cleanUp() }
        try fixture.write("a.md", "# Notes\n\n## Misc\n\nSomebody said we should build something someday.\n")
        try fixture.write("b.md", "# Notes two\n\n## Build\n\nRun the script.\n")
        try fixture.write("c.md", "# Other\n\n## Lunch\n\nSandwiches.\n")
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let results = try index.search(query: "build", limit: 5)
        #expect(results.count == 2)
        #expect(results.first?.path.hasSuffix("b.md") == true)
        #expect(results[0].score > results[1].score)
    }

    @Test func emptyAndHostileQueriesAreSafe() throws {
        let fixture = try BrainFixture.standard()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        #expect(try index.search(query: "the", limit: 5).isEmpty)
        #expect(try index.search(query: "", limit: 5).isEmpty)
        _ = try index.search(query: "port\" OR *", limit: 5)
        _ = try index.search(query: "NEAR(a b) col:x ^ - \"", limit: 5)
        #expect(try index.search(query: "port", limit: 0).count == 1)
    }
}

@Suite("BrainIndex passages")
struct BrainIndexPassageTests {
    @Test func projectNamedInTheWindowComesFirst() throws {
        let fixture = try BrainFixture.standard()
        try fixture.addFillerNotes()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let passages = try index.passages(
            forQuestion: "how do I run the build", frontAppName: "Xcode",
            frontWindowTitle: "clicky-fork - Package.swift", projectNames: ["demo-server", "clicky-fork"])
        #expect(!passages.isEmpty)
        #expect(passages.allSatisfy { $0.path.contains("clicky-fork") })
    }

    @Test func boostReordersEqualNotes() throws {
        let fixture = try BrainFixture()
        defer { fixture.cleanUp() }
        // Same wording; filler notes keep the rarity realistic.
        try fixture.write("projects/alpha/notes.md", "## Quokka rollout\n\nRun the quokka rollout from the lab.\n")
        try fixture.write("projects/beta/notes.md", "## Quokka rollout\n\nRun the quokka rollout from the lab.\n")
        try fixture.addFillerNotes()
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let boostedBeta = try index.passages(
            forQuestion: "quokka rollout", frontAppName: nil, frontWindowTitle: "Beta - editor", projectNames: ["alpha", "beta"])
        #expect(boostedBeta.first?.path.contains("/beta/") == true)
        let boostedAlpha = try index.passages(
            forQuestion: "quokka rollout", frontAppName: "Alpha", frontWindowTitle: nil, projectNames: ["alpha", "beta"])
        #expect(boostedAlpha.first?.path.contains("/alpha/") == true)
        #expect(boostedAlpha.count == 2)
    }

    @Test func screenOnlyQuestionsGetNothing() throws {
        let fixture = try BrainFixture.standard()
        try fixture.addFillerNotes()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        for question in ["where is the save button", "what does this error mean", "the", ""] {
            let passages = try index.passages(
                forQuestion: question, frontAppName: "Safari", frontWindowTitle: "Example", projectNames: [])
            #expect(passages.isEmpty, "\(question)")
        }
    }

    @Test func noteQuestionsReturnTheirNote() throws {
        let fixture = try BrainFixture.standard()
        try fixture.addFillerNotes()
        defer { fixture.cleanUp() }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let portPassages = try index.passages(
            forQuestion: "what port does the demo server use", frontAppName: nil, frontWindowTitle: nil, projectNames: [])
        #expect(portPassages.first?.path.hasSuffix("demo-server.md") == true)
        let leaguePassages = try index.passages(
            forQuestion: "which lineup moves for league 420987259", frontAppName: nil, frontWindowTitle: nil, projectNames: [])
        #expect(leaguePassages.first?.path.hasSuffix("README.md") == true)
    }

    @Test func budgetCapsPassagesFilesAndCharacters() throws {
        let fixture = try BrainFixture()
        try fixture.addFillerNotes()
        defer { fixture.cleanUp() }
        let longBody = (0..<40).map { "zebra stripe line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        for number in 0..<6 { try fixture.write("f\(number).md", "# Zebra \(number)\n\n## Zebra facts\n\n\(longBody)\n") }
        try fixture.write("g.md", (0..<5).map { "## Zebra part \($0)\n\nzebra stripes \($0)\n" }.joined(separator: "\n"))
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let passages = try index.passages(forQuestion: "zebra stripe", frontAppName: nil, frontWindowTitle: nil, projectNames: [])
        #expect(passages.count == 4)
        #expect(passages.reduce(0) { $0 + $1.text.count } <= BrainIndex.maximumPassageCharacters)
        let perFile = Dictionary(grouping: passages, by: \.path).mapValues(\.count)
        #expect(perFile.values.allSatisfy { $0 <= 2 })
    }

    @Test func overlongPassageIsCutAtALineBoundary() throws {
        let fixture = try BrainFixture()
        try fixture.addFillerNotes()
        defer { fixture.cleanUp() }
        let longBody = (0..<50).map { "giraffe line \($0) " + String(repeating: "y", count: 150) }.joined(separator: "\n")
        for number in 0..<3 { try fixture.write("f\(number).md", "# Giraffe \(number)\n\n\(longBody)\n") }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        try index.update(searchFolders: [fixture.root])
        let passages = try index.passages(forQuestion: "giraffe", frontAppName: nil, frontWindowTitle: nil, projectNames: [])
        #expect(!passages.isEmpty)
        #expect(passages.reduce(0) { $0 + $1.text.count } <= BrainIndex.maximumPassageCharacters)
        for passage in passages {
            #expect(passage.endLine - passage.startLine + 1 == passage.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
    }
}

@Suite("BrainIndex speed")
struct BrainIndexSpeedTests {
    @Test func twoThousandFilesIndexQuickly() throws {
        let fixture = try BrainFixture()
        defer { fixture.cleanUp() }
        let vocabulary = (0..<400).map { "word\($0)" }
        var generator = SystemRandomNumberGenerator()
        for fileNumber in 0..<2_000 {
            var text = "# File \(fileNumber)\n\n"
            for sectionNumber in 0..<6 {
                text += "## Section \(sectionNumber)\n\n"
                for _ in 0..<10 {
                    text += (0..<14).map { _ in vocabulary.randomElement(using: &generator)! }.joined(separator: " ") + "\n"
                }
                text += "\n"
            }
            try fixture.write("d\(fileNumber % 40)/file\(fileNumber).md", text)
        }
        let index = try BrainIndex(databaseURL: fixture.databaseURL)
        let summary = try index.update(searchFolders: [fixture.root])
        print("BRAIN-BENCH build: \(summary.filesIndexed) files, \(summary.chunkCount) chunks, \(summary.seconds) s")
        #expect(summary.filesIndexed == 2_000)
        #expect(summary.seconds < 10)
        let started = Date()
        _ = try index.search(query: "word5 word77 section", limit: 20)
        print("BRAIN-BENCH query: \(Date().timeIntervalSince(started) * 1000) ms")
        let rebuild = try index.update(searchFolders: [fixture.root])
        print("BRAIN-BENCH no-change update: \(rebuild.seconds) s")
        #expect(rebuild.filesUnchanged == 2_000)
    }
}
