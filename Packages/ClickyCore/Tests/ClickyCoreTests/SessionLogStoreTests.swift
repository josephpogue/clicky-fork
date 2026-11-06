import Foundation
import Testing
@testable import ClickyCore

struct SessionLogStoreTests {
    typealias Support = SessionLogTestSupport

    private func writeJPEG(_ store: SessionStore, sessionID: String, fileName: String) async throws -> URL {
        let url = await store.shotsDirectory(sessionID: sessionID).appendingPathComponent(fileName)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        return url
    }

    @Test func sessionsStartedInTheSameSecondGetADistinctIdWithASuffix() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let startTime = Support.date("2026-11-05T14:02:10-05:00")

        let first = try await store.startSession(at: startTime, timeZone: Support.newYork)
        let second = try await store.startSession(at: startTime, timeZone: Support.newYork)
        let third = try await store.startSession(at: startTime, timeZone: Support.newYork)

        #expect(first.id == "2026-11-05-140210")
        #expect(second.id == "2026-11-05-140210-2")
        #expect(third.id == "2026-11-05-140210-3")
        let folder = locations.sessionsDirectory.appendingPathComponent(first.id)
        for name in ["session.json", "events.jsonl", "shots"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
    }

    @Test func aFinishedSessionHasALogCleanedShotsAndAListEntry() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let start = Support.date("2026-11-05T14:02:10-05:00")
        let metadata = try await store.startSession(at: start, timeZone: Support.newYork)
        let id = metadata.id

        let first = Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100)
        let nearDuplicate = Support.group(2, .screenChange, app: "Safari", title: "A", gray: 110)
        let firstFile = try await writeJPEG(store, sessionID: id, fileName: "0001-screen1.jpg")
        let duplicateFile = try await writeJPEG(store, sessionID: id, fileName: "0002-screen1.jpg")

        try await store.append(SessionEvent(time: start.addingTimeInterval(5), kind: .utterance(text: "hello")), sessionID: id)
        try await store.append(
            SessionEvent(time: start.addingTimeInterval(6), kind: .focusChanged(appName: "Safari", windowTitle: "A")),
            sessionID: id
        )
        try await store.recordShotGroup(first, sessionID: id)
        try await store.recordShotGroup(nearDuplicate, sessionID: id)

        let end = start.addingTimeInterval(60)
        let finished = try await store.finishSession(
            sessionID: id, at: end, summary: "Looked at Safari.", timeZone: Support.newYork
        )

        // Gray 110 vs 100 is 10/255 = 0.039, under 0.10, so group 2 goes.
        #expect(finished.cleanedUp)
        #expect(finished.endedAt == end)
        #expect(finished.summary == "Looked at Safari.")
        #expect(FileManager.default.fileExists(atPath: firstFile.path))
        #expect(!FileManager.default.fileExists(atPath: duplicateFile.path))

        let logPath = locations.sessionsDirectory.appendingPathComponent(id).appendingPathComponent("log.md")
        let log = try String(contentsOf: logPath, encoding: .utf8)
        #expect(log.contains("**Summary:** Looked at Safari."))
        #expect(log.contains("![screen 1](shots/0001-screen1.jpg)"))
        #expect(!log.contains("0002-screen1.jpg"))
        #expect(log.contains("Session stopped."))

        let listed = try await store.listSessions()
        #expect(listed.map(\.id) == [id])
        #expect(listed.first?.cleanedUp == true)

        let loaded = try await store.loadSession(id: id)
        #expect(loaded.shotGroups.map(\.id) == [1])
        #expect(loaded.events.first?.kind == .sessionStarted)
        #expect(loaded.events.last?.kind == .sessionStopped)
        // started, utterance, focus, 2 screenshots, stopped
        #expect(loaded.events.count == 6)
    }

    @Test func screenshotsTiedToQuestionsSurviveCleanup() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let start = Support.date("2026-11-05T14:02:10-05:00")
        let id = try await store.startSession(at: start, timeZone: Support.newYork).id
        try await store.recordShotGroup(Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100), sessionID: id)
        // Group 2 looks the same as group 1 but a question sent it as an earlier-moment shot.
        try await store.recordShotGroup(Support.group(2, .screenChange, app: "Safari", title: "A", gray: 100), sessionID: id)
        try await store.recordShotGroup(Support.group(3, .question, app: "Safari", title: "A", gray: 100), sessionID: id)
        try await store.append(
            SessionEvent(time: start.addingTimeInterval(9), kind: .question(text: "q", shotGroupID: 3, earlierShotGroupIDs: [2])),
            sessionID: id
        )

        _ = try await store.finishSession(sessionID: id, at: start.addingTimeInterval(20), summary: nil, timeZone: Support.newYork)

        let loaded = try await store.loadSession(id: id)
        #expect(loaded.shotGroups.map(\.id) == [1, 2, 3])
    }

    @Test func listSessionsIsNewestFirstSkipsUnreadableFoldersAndKeepsCrashedSessions() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let older = try await store.startSession(at: Support.date("2026-11-04T09:00:00-05:00"), timeZone: Support.newYork)
        let newer = try await store.startSession(at: Support.date("2026-11-05T09:00:00-05:00"), timeZone: Support.newYork)
        let broken = locations.sessionsDirectory.appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let listed = try await store.listSessions()

        #expect(listed.map(\.id) == [newer.id, older.id])
        // Neither session was finished (as after a crash): still listed, with no end time.
        #expect(listed.allSatisfy { $0.endedAt == nil })

        let finished = try await store.finishSession(
            sessionID: older.id, at: Support.date("2026-11-04T09:30:00-05:00"), summary: nil, timeZone: Support.newYork
        )
        #expect(finished.cleanedUp)
        #expect(finished.endedAt != nil)
    }

    @Test func updateMetadataPersistsTheSavedFields() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        var metadata = try await store.startSession(at: Support.date("2026-11-05T09:00:00-05:00"), timeZone: Support.newYork)

        metadata.savedVaultNotePath = "Notes/x.md"
        metadata.savedProject = "Invoices"
        try await store.updateMetadata(metadata)

        let loaded = try await store.loadSession(id: metadata.id)
        #expect(loaded.metadata.savedVaultNotePath == "Notes/x.md")
        #expect(loaded.metadata.savedProject == "Invoices")
    }

    @Test func eachEventIsOneLineOnDiskEvenWhenTheTextHasNewlines() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let start = Support.date("2026-11-05T09:00:00-05:00")
        let id = try await store.startSession(at: start, timeZone: Support.newYork).id

        try await store.append(SessionEvent(time: start, kind: .utterance(text: "line one\nline two")), sessionID: id)

        let raw = try String(
            contentsOf: locations.sessionsDirectory.appendingPathComponent(id).appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        // sessionStarted plus the utterance: two lines.
        #expect(raw.split(separator: "\n").count == 2)
        let loaded = try await store.loadSession(id: id)
        #expect(loaded.events.last?.kind == .utterance(text: "line one\nline two"))
    }
}
