import Foundation
import Testing
@testable import ClickyCore

struct SessionStoreRecordSaveTests {
    typealias Support = SessionLogTestSupport

    /// The bug: a detail window opened while the session ran kept the unfinished metadata, and Save wrote it back.
    @Test func recordingASaveKeepsTheFinishedSessionsEndSummaryAndCleanup() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let start = Support.date("2026-11-05T14:02:10-05:00")
        let running = try await store.startSession(at: start, timeZone: Support.newYork)
        // A detail window opened now would hold this unfinished metadata. Then the user presses Stop.
        let end = start.addingTimeInterval(300)
        _ = try await store.finishSession(sessionID: running.id, at: end, summary: "Fixed the login form.", timeZone: Support.newYork)

        let saved = try await store.recordSave(sessionID: running.id, savedVaultNotePath: "Projects/Login/note.md", savedProject: "Login")

        #expect(saved.endedAt == end)
        #expect(saved.summary == "Fixed the login form.")
        #expect(saved.cleanedUp)
        #expect(saved.savedVaultNotePath == "Projects/Login/note.md")
        #expect(saved.savedProject == "Login")
        let onDisk = try await store.loadSession(id: running.id).metadata
        #expect(onDisk == saved)
        #expect(onDisk.endedAt == end)
    }

    @Test func recordingASaveWithNoProjectClearsAnEarlierProject() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let metadata = try await store.startSession(at: Support.date("2026-11-05T14:02:10-05:00"), timeZone: Support.newYork)
        _ = try await store.recordSave(sessionID: metadata.id, savedVaultNotePath: "A/n.md", savedProject: "A")

        let saved = try await store.recordSave(sessionID: metadata.id, savedVaultNotePath: "n.md", savedProject: nil)

        #expect(saved.savedVaultNotePath == "n.md")
        #expect(saved.savedProject == nil)
    }
}
