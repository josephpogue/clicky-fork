import Foundation
import Testing
@testable import ClickyCore

struct AppDataLocationsTests {
    @Test func dataDirectoryOverrideSetsTheRootAndEveryFolderBelowIt() {
        let locations = AppDataLocations.standard(environment: ["CLICKY_DATA_DIR": "/tmp/x"])

        #expect(locations.root.path == "/tmp/x")
        #expect(locations.sessionsDirectory.path == "/tmp/x/sessions")
        #expect(locations.claudeConfigDirectory.path == "/tmp/x/providers/claude-config")
        #expect(locations.codexHomeDirectory.path == "/tmp/x/providers/codex-home")
        #expect(locations.providerWorkingDirectory.path == "/tmp/x/providers/workdir")
    }

    @Test func withoutTheOverrideTheRootIsClickyForkInApplicationSupport() {
        let locations = AppDataLocations.standard(environment: [:])

        #expect(locations.root.lastPathComponent == "Clicky Fork")
        #expect(locations.root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func createDirectoriesMakesEveryFolder() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-core-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let locations = AppDataLocations.standard(environment: ["CLICKY_DATA_DIR": temporaryRoot.path])

        try locations.createDirectories()

        for folder in [
            locations.sessionsDirectory,
            locations.claudeConfigDirectory,
            locations.codexHomeDirectory,
            locations.providerWorkingDirectory,
        ] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}
