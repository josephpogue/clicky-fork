import Foundation
import Testing
@testable import ClickyCore

struct BrainFileRulesTests {
    @Test(arguments: [
        "/f/.env", "/f/app/.env.production.local", "/f/prod.env", "/f/keys/server.pem", "/f/id_ed25519",
        "/f/aws-credentials.json", "/f/notes/api-token.txt", "/f/.git/config", "/f/node_modules/x/README.md",
        "/f/.ssh/config", "/f/notes/tokenizer-design.md",
    ])
    func neverReadablePathsAreRefused(path: String) {
        #expect(BrainFileRules.isNeverReadable(path: path))
    }

    @Test(arguments: ["/f/README.md", "/f/Wiki/index.md", "/f/projects/app/Sources/Main.swift"])
    func ordinaryPathsAreReadable(path: String) {
        #expect(!BrainFileRules.isNeverReadable(path: path))
    }

    @Test func indexableFiles() {
        #expect(BrainFileRules.isIndexableFile(path: "a.md", byteCount: 100))
        #expect(BrainFileRules.isIndexableFile(path: "a.MD", byteCount: 100))
        #expect(BrainFileRules.isIndexableFile(path: "a.txt", byteCount: 100))
        #expect(!BrainFileRules.isIndexableFile(path: "a.swift", byteCount: 100))
        #expect(!BrainFileRules.isIndexableFile(path: "a.md", byteCount: 600 * 1024))
        #expect(!BrainFileRules.isIndexableFile(path: ".env.md", byteCount: 100))
    }

    @Test(arguments: [".git", "node_modules", "clicky-fork-worktrees", "espn-fantasy-prod", "build", ".next", "DerivedData", ".obsidian"])
    func skippedDirectories(name: String) {
        #expect(BrainFileRules.isSkippedDirectoryForIndex(name: name))
    }

    @Test(arguments: ["Wiki", "projects", "docs"])
    func keptDirectories(name: String) {
        #expect(!BrainFileRules.isSkippedDirectoryForIndex(name: name))
    }
}
