import Foundation
import Testing

@testable import ClickyCore

private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func databaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("brain-fx2-index-\(UUID().uuidString)/index.sqlite")
}

private func removeDatabase(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Common everyday words, so the corpus has a realistic (low) rarity for them.
private let everydayVocabulary = [
    "save", "button", "error", "mean", "click", "window", "open", "file", "menu", "screen", "text", "name", "list",
    "item", "page", "view", "form", "field", "user", "time", "day", "note", "plan", "work", "call", "email", "send",
    "check", "update", "change", "review", "meeting", "task", "team", "budget", "report", "draft", "share", "link",
    "folder", "setting", "option", "tab", "icon", "panel", "dialog", "message", "alert", "code", "test", "run", "port",
    "server", "lab", "deploy", "script", "fix", "bug", "issue", "ticket",
]

private func writeFillerNotes(into tree: BrainTempTree, count: Int) throws {
    var seed: UInt64 = 42
    func nextNumber() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(seed >> 33)
    }
    for noteNumber in 0..<count {
        var text = "# Topic \(noteNumber)\n\n"
        for partNumber in 0..<3 {
            text += "## Part \(partNumber)\n\n"
            text += (0..<25).map { _ in everydayVocabulary[nextNumber() % everydayVocabulary.count] }.joined(separator: " ") + "\n\n"
        }
        try tree.write("filler/f\(noteNumber).md", text)
    }
}

@Suite("BrainIndex reads never wait for an update")
struct BrainIndexReadsDuringUpdateTests {
    @Test func aQuestionDuringABigBuildAnswersAtOnce() async throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        try tree.write("small/known.md", "# Quokka plan\n\n## Rollout\n\nThe quokka rollout happens on Friday.\n")
        let smallFolder = tree.root.appendingPathComponent("small")
        let index = try BrainIndex(databaseURL: url)
        try index.update(searchFolders: [smallFolder])

        // A big folder to add: enough files that the build runs for a good while. The writing and the build run on
        // their own threads so they never hold a pool thread (the speech tests' timers share this process).
        let bigFolder = tree.url("big")
        try await DedicatedThreadJob<Void> {
            for fileNumber in 0..<3_000 {
                var text = "# Big \(fileNumber)\n\n"
                for sectionNumber in 0..<6 {
                    text += "## Section \(sectionNumber)\n\n"
                    text += (0..<40).map { "bigword\(($0 * 7 + fileNumber + sectionNumber) % 500)" }.joined(separator: " ") + "\n\n"
                }
                try tree.write("big/d\(fileNumber % 30)/f\(fileNumber).md", text)
            }
        }.value()
        let builder = DedicatedThreadJob<Void> {
            _ = try index.update(searchFolders: [smallFolder, bigFolder])
        }
        // Let the walk end and the writing begin.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!builder.isFinished, "the build must still be running for this test to mean anything")

        var slowestMilliseconds = 0.0
        for _ in 0..<5 {
            let started = Date()
            _ = try index.passages(
                forQuestion: "when is the quokka rollout", frontAppName: nil, frontWindowTitle: nil, projectNames: [])
            _ = try index.search(query: "quokka", limit: 5)
            _ = try index.indexedFiles(named: "known.md")
            _ = try index.repositoryProjectNames()
            slowestMilliseconds = max(slowestMilliseconds, Date().timeIntervalSince(started) * 1000)
        }
        let stillBuilding = !builder.isFinished
        try await builder.value()
        #expect(stillBuilding, "the reads must have run while the build was running")
        #expect(slowestMilliseconds < 100, "slowest read round \(slowestMilliseconds) ms")
    }
}

@Suite("BrainIndex walker safety")
struct BrainIndexWalkerSafetyTests {
    private func makeFIFO(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(url.path, 0o600) == 0)
    }

    @Test func aFIFONamedLikeANoteDoesNotHangTheWalk() async throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        try tree.write("real.md", "# Real note\n\nThe okapi census is on Tuesday.\n")
        try makeFIFO(at: tree.url("trap.md"))
        let index = try BrainIndex(databaseURL: url)
        let finished = DoneFlag()
        let summaryBox = SummaryBox()
        // Its own thread: if the open ever waits for a writer again, only this thread hangs, not the test pool.
        Thread.detachNewThread {
            summaryBox.summary = try? index.update(searchFolders: [tree.root])
            finished.set()
        }
        // Without the fix this never finishes (the open of a FIFO waits for a writer).
        for _ in 0..<50 where !finished.isSet { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(finished.isSet, "update hung on a FIFO")
        #expect(summaryBox.summary?.filesIndexed == 1)
        #expect(try index.search(query: "okapi", limit: 5).count == 1)
    }

    private final class SummaryBox: @unchecked Sendable { var summary: BrainIndexUpdateSummary? }

    @Test func aHardLinkToAFileOutsideTheFolderIsNotIndexed() throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        let inside = try tree.folder("inside")
        try tree.write("outside/private-notes.md", "# Private\n\nThe zebra codeword is MARIGOLD.\n")
        try tree.write("inside/ok.md", "# Fine\n\nA harmless note.\n")
        try FileManager.default.linkItem(
            at: tree.url("outside/private-notes.md"), to: tree.url("inside/innocent.md"))
        let index = try BrainIndex(databaseURL: url)
        let summary = try index.update(searchFolders: [inside])
        #expect(summary.filesIndexed == 1)
        #expect(try index.search(query: "marigold", limit: 5).isEmpty)
    }

    @Test func aFileThatGainsASecondLinkAfterIndexingIsDroppedAtTheNextUpdate() throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        let inside = try tree.folder("inside")
        try tree.write("inside/note.md", "# Note\n\nThe ibex schedule is fixed.\n")
        let index = try BrainIndex(databaseURL: url)
        try index.update(searchFolders: [inside])
        #expect(try index.search(query: "ibex", limit: 5).count == 1)
        try FileManager.default.linkItem(at: tree.url("inside/note.md"), to: tree.url("elsewhere.md"))
        let summary = try index.update(searchFolders: [inside])
        #expect(summary.filesRemoved == 1)
        #expect(try index.search(query: "ibex", limit: 5).isEmpty)
    }

    @Test func theReadStepRefusesEverythingButAPlainSingleNameFile() throws {
        let tree = try BrainTempTree()
        defer { tree.cleanUp() }
        try tree.write("plain.md", "# Plain\n")
        try tree.write("target.md", "# Target\n")
        try FileManager.default.createSymbolicLink(at: tree.url("link.md"), withDestinationURL: tree.url("target.md"))
        try FileManager.default.linkItem(at: tree.url("target.md"), to: tree.url("second-name.md"))
        try makeFIFO(at: tree.url("pipe.md"))
        try tree.write("huge.md", String(repeating: "a", count: BrainFileRules.maximumIndexedFileBytes + 1))
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("plain.md").path) == Data("# Plain\n".utf8))
        // A path swapped for a symlink between the check and the read is refused by O_NOFOLLOW.
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("link.md").path) == nil)
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("second-name.md").path) == nil)
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("pipe.md").path) == nil)
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("huge.md").path) == nil)
        #expect(BrainIndex.readIndexableFile(atPath: tree.url("missing.md").path) == nil)
    }
}

@Suite("BrainIndex passages follow the current folder list")
struct BrainIndexCurrentFolderTests {
    @Test func passagesOfARemovedFolderAreDroppedEvenWhileTheIndexStillHoldsThem() throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        let alpha = try tree.folder("alpha"), beta = try tree.folder("beta")
        try tree.write("alpha/a.md", "# Quokka plan\n\n## Rollout\n\nThe quokka rollout happens in alpha.\n")
        try tree.write("beta/b.md", "# Wombat plan\n\n## Rollout\n\nThe wombat rollout happens in beta.\n")
        try writeFillerNotes(into: tree, count: 300)
        let index = try BrainIndex(databaseURL: url)
        try index.update(searchFolders: [alpha, beta, tree.root.appendingPathComponent("filler")])

        let both = try index.passages(
            forQuestion: "wombat rollout", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [alpha, beta])
        #expect(both.contains { $0.path.hasSuffix("b.md") })
        // beta removed in Settings; the rebuild has not run.
        let afterRemoval = try index.passages(
            forQuestion: "wombat rollout", frontAppName: nil, frontWindowTitle: nil, projectNames: [], searchFolders: [alpha])
        #expect(!afterRemoval.contains { $0.path.hasSuffix("b.md") })
        // All removed.
        let none = try index.passages(
            forQuestion: "quokka rollout", frontAppName: nil, frontWindowTitle: nil, projectNames: [], searchFolders: [])
        #expect(none.isEmpty)
        // Removed, then re-added before the next session: back.
        let readded = try index.passages(
            forQuestion: "wombat rollout", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [alpha, beta])
        #expect(readded.contains { $0.path.hasSuffix("b.md") })
    }

    @Test func aRowForANeverReadablePathIsDroppedEvenIfTheWalkerStoredIt() throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        let inside = try tree.folder("inside")
        try tree.write("inside/ok.md", "# Gazelle plan\n\n## Gazelle schedule\n\nThe gazelle schedule.\n")
        try writeFillerNotes(into: tree, count: 300)
        let index = try BrainIndex(databaseURL: url)
        try index.update(searchFolders: [inside, tree.root.appendingPathComponent("filler")])
        // The same row seen through a folder list that does not hold it.
        let elsewhere = try tree.folder("elsewhere")
        let passages = try index.passages(
            forQuestion: "gazelle schedule", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [elsewhere])
        #expect(passages.isEmpty)
    }
}

@Suite("BrainIndex score floor curve")
struct BrainIndexScoreFloorTests {
    @Test func theCurveMatchesTheBenchPoints() {
        #expect(abs(BrainIndex.scoreFloor(forChunkCount: 27_527) - 14.0) < 0.1)
        #expect(abs(BrainIndex.scoreFloor(forChunkCount: 4_680) - 11.5) < 0.1)
    }

    @Test func smallCorporaStayAtTheMinimumAndTheCurveOnlyRises() {
        #expect(BrainIndex.scoreFloor(forChunkCount: 0) == BrainIndex.minimumScoreFloor)
        #expect(BrainIndex.scoreFloor(forChunkCount: 5) == BrainIndex.minimumScoreFloor)
        var previous = 0.0
        for chunkCount in [1, 10, 100, 1_000, 5_000, 30_000, 300_000] {
            let floor = BrainIndex.scoreFloor(forChunkCount: chunkCount)
            #expect(floor >= previous)
            previous = floor
        }
    }

    @Test func theOverrideBeatsTheCurveAndNilUsesIt() {
        #expect(BrainIndex.effectiveScoreFloor(override: 3.5, chunkCount: 27_527) == 3.5)
        #expect(BrainIndex.effectiveScoreFloor(override: nil, chunkCount: 27_527) == BrainIndex.scoreFloor(forChunkCount: 27_527))
    }

    @Test func theUpdateStoresTheChunkCountTheFloorUses() throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        try writeFillerNotes(into: tree, count: 120)
        let index = try BrainIndex(databaseURL: url)
        let summary = try index.update(searchFolders: [tree.root])
        #expect(index.currentScoreFloor() == BrainIndex.scoreFloor(forChunkCount: summary.chunkCount))
        #expect(index.currentScoreFloor() > BrainIndex.minimumScoreFloor)
    }

    /// The test Mac's fixture brain (`testenv/fixture-brain/seed.sh`), as strings.
    private func writeTestMacFixtureBrain(into tree: BrainTempTree) throws {
        try tree.write("Wiki/Projects/demo-server.md", "# Demo server\n\n## Ports\nThe demo server listens on port 4417 behind the lab proxy.\n")
        try tree.write(
            "Wiki/Projects/release.md",
            "# Release\n\n## Deploys\nDeploys go through the release script, run from the top of the repo.\n\n## Builds\nTest builds use Release, never Debug.\n")
        try tree.write("Wiki/index.md", "# Index\n\nA map of the notes.\n\n- [Demo server](Projects/demo-server.md)\n- [Release](Projects/release.md)\n")
        try tree.write("projects/demo-app/README.md", "# Demo app\n\nA tiny app used only by the test fixture.\n")
    }

    @Test func theTestMacFixtureBrainStillAttachesThePortNoteAndNothingForScreenQuestions() throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        try writeTestMacFixtureBrain(into: tree)
        let index = try BrainIndex(databaseURL: url)
        try index.update(searchFolders: [tree.root])
        let port = try index.passages(
            forQuestion: "what port does the demo server use", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [tree.root])
        #expect(port.first?.path.hasSuffix("demo-server.md") == true, "floor \(index.currentScoreFloor())")
        let save = try index.passages(
            forQuestion: "where is the save button", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [tree.root])
        #expect(save.isEmpty)
        let deploy = try index.passages(
            forQuestion: "how do I deploy a test build", frontAppName: nil, frontWindowTitle: nil, projectNames: [],
            searchFolders: [tree.root])
        #expect(deploy.first?.path.hasSuffix("release.md") == true)
    }

    @Test func aLargerCorpusRaisesTheFloorButARareWordNoteStillAttaches() async throws {
        let tree = try BrainTempTree()
        let url = databaseURL()
        defer { tree.cleanUp(); removeDatabase(url) }
        try writeTestMacFixtureBrain(into: tree)
        try tree.write("Wiki/okapi.md", "# Okapi census\n\n## Okapi counts\n\nThe okapi census is counted every Tuesday.\n")
        let index = try BrainIndex(databaseURL: url)
        // The 1,500 files and their build run on their own thread, off the cooperative pool.
        let summary = try await DedicatedThreadJob<BrainIndexUpdateSummary> {
            try writeFillerNotes(into: tree, count: 1_500)
            return try index.update(searchFolders: [tree.root])
        }.value()
        #expect(summary.chunkCount > 4_000)
        #expect(index.currentScoreFloor() > 11)
        let okapi = try index.passages(
            forQuestion: "when is the okapi census counted", frontAppName: nil, frontWindowTitle: nil, projectNames: [])
        #expect(okapi.first?.path.hasSuffix("okapi.md") == true, "floor \(index.currentScoreFloor())")
        for question in ["where is the save button", "what does this error mean", "how do I open this menu"] {
            let passages = try index.passages(
                forQuestion: question, frontAppName: nil, frontWindowTitle: nil, projectNames: [])
            #expect(passages.isEmpty, "\(question)")
        }
    }
}
