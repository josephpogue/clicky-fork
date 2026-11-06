import Foundation
import Testing
@testable import ClickyCore

/// Save must stay inside the notes folder, commit only in the notes folder's own repo, and leave
/// nothing behind when it fails. Every vault here is a fresh temp folder.
struct VaultSessionSaverSafetyTests {
    private let stem = "2026-11-05-fix-xcode-signing"

    private func input(vault: URL, project: String?, shots: [URL]) -> VaultSaveInput {
        VaultSaveInput(
            vaultRoot: vault, date: "2026-11-05", title: "Fix Xcode signing", slug: "fix-xcode-signing",
            project: project, questionShotFiles: shots, isDryRun: false)
    }

    private func fileExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: Enclosing repo

    @Test func aNotesFolderInsideSomeoneElsesRepoIsWrittenButNeverCommitted() throws {
        let outer = try VaultTestSupport.makeTempFolder()
        try VaultTestSupport.git(["init", "-q"], in: outer)
        try VaultTestSupport.git(["config", "user.name", "Test User"], in: outer)
        try VaultTestSupport.git(["config", "user.email", "test@example.com"], in: outer)
        try VaultTestSupport.git(["config", "commit.gpgsign", "false"], in: outer)
        try VaultTestSupport.write("seed", to: outer.appendingPathComponent("seed.txt"))
        try VaultTestSupport.git(["add", "-A"], in: outer)
        try VaultTestSupport.git(["commit", "-q", "-m", "Seed"], in: outer)
        let notes = outer.appendingPathComponent("notes", isDirectory: true)
        try VaultTestSupport.write("# Homelab\n\nThe lab.\n", to: notes.appendingPathComponent("Wiki/Projects/homelab.md"))

        let result = try VaultSessionSaver.save(input(vault: notes, project: "homelab", shots: []), renderLog: { _ in "a" }).get()

        #expect(!result.committed)
        #expect(result.commitError?.isEmpty == false)
        #expect(fileExists(result.notePath))
        #expect(try VaultTestSupport.git(["log", "--format=%s"], in: outer) == "Seed")
        #expect(try VaultTestSupport.git(["status", "--porcelain"], in: outer).contains("notes/"))
    }

    // MARK: Symlinks

    @Test func aSessionsFolderLinkedOutsideTheNotesFolderRefusesTheSave() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let outside = try VaultTestSupport.makeTempFolder()
        let sources = vault.appendingPathComponent("_sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sources.appendingPathComponent("sessions"), withDestinationURL: outside)

        let outcome = VaultSessionSaver.save(input(vault: vault, project: "homelab", shots: []), renderLog: { _ in "a" })

        guard case .failure(.writeFailed) = outcome else { Issue.record("expected writeFailed, got \(outcome)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let page = try String(contentsOf: vault.appendingPathComponent("Wiki/Projects/homelab.md"), encoding: .utf8)
        #expect(page == "# Homelab\n\nThe lab.\n")
    }

    @Test func aLinkedSourcesFolderOutsideTheNotesFolderRefusesTheSave() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let outside = try VaultTestSupport.makeTempFolder()
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("_sources"), withDestinationURL: outside)

        let outcome = VaultSessionSaver.save(input(vault: vault, project: nil, shots: []), renderLog: { _ in "a" })

        guard case .failure(.writeFailed) = outcome else { Issue.record("expected writeFailed, got \(outcome)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func aProjectPageLinkedOutsideIsNotListedAndSaveToItIsRefused() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let outside = try VaultTestSupport.makeTempFolder()
        let target = outside.appendingPathComponent("elsewhere.md")
        try VaultTestSupport.write("# Elsewhere\n", to: target)
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("Wiki/Projects/linked.md"), withDestinationURL: target)

        #expect(VaultProjects.list(vaultRoot: vault) == ["clicky-fork", "homelab", "meetily-fork"])
        let outcome = VaultSessionSaver.save(input(vault: vault, project: "linked", shots: []), renderLog: { _ in "a" })

        #expect(outcome.failureValue == .unknownProject("linked"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "# Elsewhere\n")
        #expect(!fileExists(vault.appendingPathComponent("_sources")))
    }

    @Test func aLinkInsideTheNotesFolderIsAlsoNotListedSoItIsNeverReplaced() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("Wiki/Projects/alias.md"),
            withDestinationURL: vault.appendingPathComponent("Wiki/Projects/homelab.md"))

        #expect(!VaultProjects.list(vaultRoot: vault).contains("alias"))
    }

    @Test func aLinkAtTheNoteNameIsNeverReplacedTheNoteTakesTheNextName() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let outside = try VaultTestSupport.makeTempFolder()
        let sessions = vault.appendingPathComponent("_sources/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let taken = sessions.appendingPathComponent("\(stem).md")
        // A dangling link: the file it points at does not exist yet.
        try FileManager.default.createSymbolicLink(at: taken, withDestinationURL: outside.appendingPathComponent("new.md"))

        let result = try VaultSessionSaver.save(input(vault: vault, project: nil, shots: []), renderLog: { _ in "a" }).get()

        #expect(result.notePath.lastPathComponent == "\(stem)-2.md")
        #expect(!fileExists(outside.appendingPathComponent("new.md")))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: taken.path)) != nil)
    }

    // MARK: Failed Save

    @Test func aFailedShotCopyRemovesWhatThisSaveWroteAndTheRetryKeepsTheSameName() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let good = try VaultTestSupport.makeShots(count: 1)
        let missing = good[0].deletingLastPathComponent().appendingPathComponent("0099-gone.jpg")
        let pagePath = vault.appendingPathComponent("Wiki/Projects/homelab.md")

        let outcome = VaultSessionSaver.save(
            input(vault: vault, project: "homelab", shots: good + [missing]), renderLog: { _ in "a" })

        guard case .failure(.writeFailed) = outcome else { Issue.record("expected writeFailed, got \(outcome)"); return }
        let sessions = vault.appendingPathComponent("_sources/sessions", isDirectory: true)
        #expect(!fileExists(sessions.appendingPathComponent("\(stem).md")))
        #expect(!fileExists(sessions.appendingPathComponent(stem)))
        #expect(try String(contentsOf: pagePath, encoding: .utf8) == "# Homelab\n\nThe lab.\n")
        #expect(try VaultTestSupport.git(["status", "--porcelain"], in: vault).isEmpty)

        let retry = try VaultSessionSaver.save(
            input(vault: vault, project: "homelab", shots: good), renderLog: { _ in "a" }).get()
        #expect(retry.notePath.lastPathComponent == "\(stem).md")
    }

    @Test func aFailedSaveLeavesShotFilesAlreadyInPlaceFromEarlierSavesAlone() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let shots = try VaultTestSupport.makeShots(count: 1)
        let first = try VaultSessionSaver.save(input(vault: vault, project: nil, shots: shots), renderLog: { _ in "first" }).get()
        let missing = shots[0].deletingLastPathComponent().appendingPathComponent("0099-gone.jpg")

        let outcome = VaultSessionSaver.save(input(vault: vault, project: nil, shots: shots + [missing]), renderLog: { _ in "second" })

        guard case .failure = outcome else { Issue.record("expected failure"); return }
        #expect(fileExists(first.notePath))
        #expect(fileExists(first.shotsFolder.appendingPathComponent(shots[0].lastPathComponent)))
        #expect(!fileExists(first.notePath.deletingLastPathComponent().appendingPathComponent("\(stem)-2.md")))
        #expect(!fileExists(first.notePath.deletingLastPathComponent().appendingPathComponent("\(stem)-2")))
    }

    // MARK: Commit contents

    @Test func theCommitHoldsExactlyTheNoteItsShotsAndThePage() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        try VaultTestSupport.write("scratch", to: vault.appendingPathComponent("unrelated.txt"))
        try VaultTestSupport.write("staged", to: vault.appendingPathComponent("staged.txt"))
        try VaultTestSupport.git(["add", "staged.txt"], in: vault)
        let shots = try VaultTestSupport.makeShots(count: 2)

        let result = try VaultSessionSaver.save(
            input(vault: vault, project: "homelab", shots: shots), renderLog: { _ in "a" }).get()

        #expect(result.committed)
        let committed = try VaultTestSupport.git(["show", "--stat", "--name-only", "--format=", "HEAD"], in: vault)
            .split(separator: "\n").map(String.init).sorted()
        // Sorted by plain string order: "Wiki/..." sorts before "_sources/..." (W is 0x57, _ is 0x5F).
        #expect(committed == [
            "Wiki/Projects/homelab.md",
            "_sources/sessions/\(stem).md",
            "_sources/sessions/\(stem)/shots/0003-screen1.jpg",
            "_sources/sessions/\(stem)/shots/0005-screen2.jpg",
        ])
    }

    // MARK: Home folder

    @Test func aTildeNotesFolderResolvesToTheGivenHomeFolder() throws {
        let home = try VaultTestSupport.makeTempFolder()

        let nested = VaultRootResolver.resolve(notesFolderSetting: "~/Notes", environment: [:], homeDirectory: home)
        let bare = VaultRootResolver.resolve(notesFolderSetting: "~", environment: [:], homeDirectory: home)
        let fromEnvironment = VaultRootResolver.resolve(
            notesFolderSetting: nil, environment: ["CLICKY_VAULT_ROOT": "~/Elsewhere"], homeDirectory: home)
        let absolute = VaultRootResolver.resolve(notesFolderSetting: "/abs/Notes", environment: [:], homeDirectory: home)

        #expect(nested?.path == home.appendingPathComponent("Notes").path)
        #expect(bare?.path == home.path)
        #expect(fromEnvironment?.path == home.appendingPathComponent("Elsewhere").path)
        #expect(absolute?.path == "/abs/Notes")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
