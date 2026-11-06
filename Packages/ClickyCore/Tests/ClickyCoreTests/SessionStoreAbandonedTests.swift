import Foundation
import Testing
@testable import ClickyCore

struct SessionStoreAbandonedTests {
    typealias Support = SessionLogTestSupport

    private func writeJPEG(_ store: SessionStore, sessionID: String, fileName: String) async throws {
        let url = await store.shotsDirectory(sessionID: sessionID).appendingPathComponent(fileName)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
    }

    @Test func aCrashedSessionIsFinishedAtItsLastEventWithCleanupAndLogAndNoSummary() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let start = Support.date("2026-11-05T14:02:10-05:00")
        let crashed = try await store.startSession(at: start, timeZone: Support.newYork)
        let running = try await store.startSession(at: start.addingTimeInterval(3600), timeZone: Support.newYork)

        try await writeJPEG(store, sessionID: crashed.id, fileName: "0001-screen1.jpg")
        try await writeJPEG(store, sessionID: crashed.id, fileName: "0002-screen1.jpg")
        try await store.recordShotGroup(Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100), sessionID: crashed.id)
        // Gray 110 vs 100 is 10/255 = 0.039, a near duplicate seconds later: cleanup deletes group 2.
        try await store.recordShotGroup(Support.group(2, .screenChange, app: "Safari", title: "A", gray: 110), sessionID: crashed.id)
        let lastEventTime = start.addingTimeInterval(95)
        try await store.append(SessionEvent(time: lastEventTime, kind: .utterance(text: "last words")), sessionID: crashed.id)

        let finishedIDs = try await store.finishAbandonedSessions(exceptSessionID: running.id)

        #expect(finishedIDs == [crashed.id])
        let listed = try await store.listSessions()
        let crashedAfter = try #require(listed.first { $0.id == crashed.id })
        #expect(crashedAfter.endedAt == lastEventTime)
        #expect(crashedAfter.cleanedUp)
        #expect(crashedAfter.summary == nil)
        let folder = locations.sessionsDirectory.appendingPathComponent(crashed.id)
        let log = try String(contentsOf: folder.appendingPathComponent("log.md"), encoding: .utf8)
        #expect(log.contains("last words"))
        #expect(log.contains("![screen 1](shots/0001-screen1.jpg)"))
        #expect(!log.contains("0002-screen1.jpg"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shots/0001-screen1.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("shots/0002-screen1.jpg").path))

        // The session running now is untouched.
        let runningAfter = try #require(listed.first { $0.id == running.id })
        #expect(runningAfter.endedAt == nil)
        #expect(!runningAfter.cleanedUp)
        #expect(!FileManager.default.fileExists(
            atPath: locations.sessionsDirectory.appendingPathComponent(running.id).appendingPathComponent("log.md").path))
    }

    @Test func aSessionWithNoEventsBeyondItsStartEndsAtItsStartTime() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let start = Support.date("2026-11-05T09:00:00-05:00")
        let session = try await store.startSession(at: start, timeZone: Support.newYork)
        // Remove even the "started" line, as if the crash came before it reached the disk.
        let eventsFile = locations.sessionsDirectory.appendingPathComponent(session.id).appendingPathComponent("events.jsonl")
        try Data().write(to: eventsFile)

        let finishedIDs = try await store.finishAbandonedSessions(exceptSessionID: nil)

        #expect(finishedIDs == [session.id])
        let after = try #require(try await store.listSessions().first)
        #expect(after.endedAt == start)
    }

    @Test func finishedSessionsAndFoldersWithoutASessionFileAreLeftAlone() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let done = try await store.startSession(at: Support.date("2026-11-04T09:00:00-05:00"), timeZone: Support.newYork)
        let doneEnd = Support.date("2026-11-04T09:30:00-05:00")
        _ = try await store.finishSession(sessionID: done.id, at: doneEnd, summary: "kept", timeZone: Support.newYork)
        let stray = locations.sessionsDirectory.appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let finishedIDs = try await store.finishAbandonedSessions(exceptSessionID: nil)

        #expect(finishedIDs.isEmpty)
        let after = try #require(try await store.listSessions().first)
        #expect(after.endedAt == doneEnd)
        #expect(after.summary == "kept")
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func aCorruptSessionIsSkippedNotDeletedAndTheRestStillFinish() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let badEvents = try await store.startSession(at: Support.date("2026-11-03T09:00:00-05:00"), timeZone: Support.newYork)
        let badMetadata = try await store.startSession(at: Support.date("2026-11-04T09:00:00-05:00"), timeZone: Support.newYork)
        let good = try await store.startSession(at: Support.date("2026-11-05T09:00:00-05:00"), timeZone: Support.newYork)

        // A broken line that is not the last one (a last-line tear is tolerated).
        let eventsFile = locations.sessionsDirectory.appendingPathComponent(badEvents.id).appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: eventsFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{this is not json}\n".utf8))
        try handle.close()
        try await store.append(SessionEvent(time: Support.date("2026-11-03T09:01:00-05:00"), kind: .utterance(text: "x")), sessionID: badEvents.id)
        // A session.json that no longer parses.
        let metadataFile = locations.sessionsDirectory.appendingPathComponent(badMetadata.id).appendingPathComponent("session.json")
        try Data("{{{".utf8).write(to: metadataFile)

        let finishedIDs = try await store.finishAbandonedSessions(exceptSessionID: nil)

        #expect(finishedIDs == [good.id])
        for skipped in [badEvents.id, badMetadata.id] {
            let folder = locations.sessionsDirectory.appendingPathComponent(skipped)
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("log.md").path))
        }
        #expect(try String(contentsOf: metadataFile, encoding: .utf8) == "{{{")
    }

    @Test func runningItAgainFindsNothingLeftToFinish() async throws {
        let locations = Support.temporaryLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = SessionStore(locations: locations)
        let session = try await store.startSession(at: Support.date("2026-11-05T09:00:00-05:00"), timeZone: Support.newYork)

        #expect(try await store.finishAbandonedSessions(exceptSessionID: nil) == [session.id])
        #expect(try await store.finishAbandonedSessions(exceptSessionID: nil).isEmpty)
        let loaded = try await store.loadSession(id: session.id)
        #expect(loaded.events.filter { $0.kind == .sessionStopped }.count == 1)
    }
}
