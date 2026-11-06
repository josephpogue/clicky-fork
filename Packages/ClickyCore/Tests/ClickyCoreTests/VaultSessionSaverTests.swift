import Foundation
import Testing
@testable import ClickyCore

struct VaultSessionSaverTests {
    private func input(
        vault: URL, project: String?, shots: [URL], dryRun: Bool = false
    ) -> VaultSaveInput {
        VaultSaveInput(
            vaultRoot: vault, date: "2026-11-05", title: "Fix Xcode signing", slug: "fix-xcode-signing",
            project: project, questionShotFiles: shots, isDryRun: dryRun)
    }

    private func relativeStatus(_ vault: URL) throws -> String {
        try VaultTestSupport.git(["status", "--porcelain"], in: vault)
    }

    @Test func savesNoteShotsLinkAndCommit() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        try VaultTestSupport.write("scratch", to: vault.appendingPathComponent("unrelated.txt"))
        let shots = try VaultTestSupport.makeShots(count: 2)

        var seenStem: String?
        let result = try VaultSessionSaver.save(
            input(vault: vault, project: "homelab", shots: shots),
            renderLog: { stem in seenStem = stem; return "Body for \(stem)\n" }).get()

        let stem = "2026-11-05-fix-xcode-signing"
        #expect(seenStem == stem)
        let note = vault.appendingPathComponent("_sources/sessions/\(stem).md")
        #expect(result.notePath.standardizedFileURL == note.standardizedFileURL)
        let text = try String(contentsOf: note, encoding: .utf8)
        #expect(text == """
            ---
            title: "Fix Xcode signing"
            date: 2026-11-05
            type: session
            source: Clicky Fork
            project: homelab
            ---

            Body for \(stem)

            """)
        let shotsFolder = vault.appendingPathComponent("_sources/sessions/\(stem)/shots")
        #expect(FileManager.default.fileExists(atPath: shotsFolder.appendingPathComponent("0003-screen1.jpg").path))
        #expect(FileManager.default.fileExists(atPath: shotsFolder.appendingPathComponent("0005-screen2.jpg").path))
        #expect(result.shotsFolder.standardizedFileURL == shotsFolder.standardizedFileURL)

        let page = try String(contentsOf: vault.appendingPathComponent("Wiki/Projects/homelab.md"), encoding: .utf8)
        #expect(page == "# Homelab\n\nThe lab.\n\n## Sessions\n\n- [[\(stem)|2026-11-05 Fix Xcode signing]]\n")
        #expect(result.projectPage != nil)

        #expect(result.committed)
        #expect(result.commitError == nil)
        #expect(try VaultTestSupport.git(["log", "-1", "--format=%s"], in: vault) == "Clicky session: Fix Xcode signing")
        // Only the unrelated file is still dirty.
        #expect(try relativeStatus(vault) == "?? unrelated.txt")
    }

    @Test func savingAgainUsesNextStemAndKeepsOneHeading() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let first = try VaultSessionSaver.save(input(vault: vault, project: "homelab", shots: []), renderLog: { _ in "a" }).get()
        let second = try VaultSessionSaver.save(input(vault: vault, project: "homelab", shots: []), renderLog: { _ in "b" }).get()
        #expect(first.notePath.lastPathComponent == "2026-11-05-fix-xcode-signing.md")
        #expect(second.notePath.lastPathComponent == "2026-11-05-fix-xcode-signing-2.md")
        let page = try String(contentsOf: vault.appendingPathComponent("Wiki/Projects/homelab.md"), encoding: .utf8)
        #expect(page.components(separatedBy: "## Sessions").count == 2)
        #expect(page.components(separatedBy: "- [[").count == 3)
        #expect(page.contains("[[2026-11-05-fix-xcode-signing-2|2026-11-05 Fix Xcode signing]]"))
    }

    @Test func linkGoesUnderExistingSessionsHeadingBeforeNextHeading() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let page = vault.appendingPathComponent("Wiki/Projects/homelab.md")
        try VaultTestSupport.write("# Homelab\n\n## Sessions\n\n- [[old|2026-01-01 Old]]\n\n## Notes\n\nText\n", to: page)
        _ = try VaultSessionSaver.save(input(vault: vault, project: "homelab", shots: []), renderLog: { _ in "a" }).get()
        let text = try String(contentsOf: page, encoding: .utf8)
        #expect(text == "# Homelab\n\n## Sessions\n\n- [[old|2026-01-01 Old]]\n- [[2026-11-05-fix-xcode-signing|2026-11-05 Fix Xcode signing]]\n\n## Notes\n\nText\n")
    }

    @Test func unknownProjectIsRefusedAndNothingIsWritten() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let result = VaultSessionSaver.save(input(vault: vault, project: "nope", shots: []), renderLog: { _ in "a" })
        #expect(result.failureValue == .unknownProject("nope"))
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("_sources").path))
        #expect(try relativeStatus(vault) == "")
    }

    @Test func noProjectLeavesPagesUntouched() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let result = try VaultSessionSaver.save(input(vault: vault, project: nil, shots: []), renderLog: { _ in "a" }).get()
        #expect(result.projectPage == nil)
        #expect(result.committed)
        let text = try String(contentsOf: result.notePath, encoding: .utf8)
        #expect(!text.contains("project:"))
        #expect(try relativeStatus(vault) == "")
        let page = try String(contentsOf: vault.appendingPathComponent("Wiki/Projects/homelab.md"), encoding: .utf8)
        #expect(page == "# Homelab\n\nThe lab.\n")
    }

    @Test func noGitRepoKeepsFilesAndReportsWhy() throws {
        let vault = try VaultTestSupport.makeVault(withGit: false)
        let result = try VaultSessionSaver.save(input(vault: vault, project: "homelab", shots: []), renderLog: { _ in "a" }).get()
        #expect(!result.committed)
        #expect(result.commitError?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: result.notePath.path))
    }

    @Test func dryRunWritesNothingAndReturnsPaths() throws {
        let vault = try VaultTestSupport.makeVault(withGit: true)
        let shots = try VaultTestSupport.makeShots(count: 1)
        var renderCalled = false
        let result = try VaultSessionSaver.save(
            input(vault: vault, project: "homelab", shots: shots, dryRun: true),
            renderLog: { _ in renderCalled = true; return "a" }).get()
        #expect(result.notePath.lastPathComponent == "2026-11-05-fix-xcode-signing.md")
        #expect(result.projectPage?.lastPathComponent == "homelab.md")
        #expect(!result.committed)
        #expect(!renderCalled)
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("_sources").path))
        #expect(try relativeStatus(vault) == "")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
