import Foundation

/// A session read back from its folder.
public struct LoadedSession: Equatable, Sendable {
    public var metadata: SessionMetadata
    public var events: [SessionEvent]
    /// Only the groups whose screenshots are still on disk (cleanup removes the rest).
    public var shotGroups: [ShotGroup]
}

public enum SessionStoreError: Error, Equatable {
    case invalidSessionID(String)
    case sessionNotFound(String)
    case unreadableLogLine(sessionID: String, lineNumber: Int)
}

/// Keeps each session as a folder: `session.json`, an append-only `events.jsonl`, `shots.jsonl`,
/// a `shots/` folder and, after Stop, a markdown `log.md`.
public actor SessionStore {
    private let locations: AppDataLocations
    private let fileManager = FileManager.default

    public init(locations: AppDataLocations) {
        self.locations = locations
    }

    // MARK: Folders

    public nonisolated func shotsDirectory(sessionID: String) -> URL {
        sessionDirectory(sessionID: sessionID).appendingPathComponent("shots", isDirectory: true)
    }

    private nonisolated func sessionDirectory(sessionID: String) -> URL {
        locations.sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func existingSessionDirectory(sessionID: String) throws -> URL {
        // The id becomes a folder name, so it can never hold a path separator or be a dot name.
        guard !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." else {
            throw SessionStoreError.invalidSessionID(sessionID)
        }
        let directory = sessionDirectory(sessionID: sessionID)
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("session.json").path) else {
            throw SessionStoreError.sessionNotFound(sessionID)
        }
        return directory
    }

    // MARK: Start and append

    public func startSession(at startTime: Date, timeZone: TimeZone = .current) throws -> SessionMetadata {
        try fileManager.createDirectory(at: locations.sessionsDirectory, withIntermediateDirectories: true)

        let baseID = SessionLogText.timeFormatter(pattern: "yyyy-MM-dd-HHmmss", timeZone: timeZone).string(from: startTime)
        var sessionID = baseID
        var suffixNumber = 2
        while fileManager.fileExists(atPath: sessionDirectory(sessionID: sessionID).path) {
            sessionID = "\(baseID)-\(suffixNumber)"
            suffixNumber += 1
        }

        try fileManager.createDirectory(at: shotsDirectory(sessionID: sessionID), withIntermediateDirectories: true)
        let directory = sessionDirectory(sessionID: sessionID)
        fileManager.createFile(atPath: directory.appendingPathComponent("events.jsonl").path, contents: nil)

        let metadata = SessionMetadata(id: sessionID, startedAt: startTime)
        try writeMetadata(metadata, in: directory)
        try appendLine(SessionEvent(time: startTime, kind: .sessionStarted), to: directory.appendingPathComponent("events.jsonl"))
        return metadata
    }

    public func append(_ event: SessionEvent, sessionID: String) throws {
        let directory = try existingSessionDirectory(sessionID: sessionID)
        try appendLine(event, to: directory.appendingPathComponent("events.jsonl"))
    }

    public func recordShotGroup(_ group: ShotGroup, sessionID: String) throws {
        let directory = try existingSessionDirectory(sessionID: sessionID)
        try appendLine(group, to: directory.appendingPathComponent("shots.jsonl"))
        try appendLine(
            SessionEvent(time: group.capturedAt, kind: .screenshot(shotGroupID: group.id)),
            to: directory.appendingPathComponent("events.jsonl")
        )
    }

    // MARK: Finish

    /// Stops the session, removes near-duplicate screenshots, writes `log.md` and marks the session cleaned up.
    /// Safe to run again on a session a crash left half finished: it adds no second "stopped" event.
    public func finishSession(
        sessionID: String,
        at endTime: Date,
        summary: String?,
        timeZone: TimeZone = .current
    ) throws -> SessionMetadata {
        let directory = try existingSessionDirectory(sessionID: sessionID)
        var metadata = try readMetadata(in: directory)
        var events = try readLines(SessionEvent.self, from: directory.appendingPathComponent("events.jsonl"), sessionID: sessionID)

        if !events.contains(where: { $0.kind == .sessionStopped }) {
            let stoppedEvent = SessionEvent(time: endTime, kind: .sessionStopped)
            try appendLine(stoppedEvent, to: directory.appendingPathComponent("events.jsonl"))
            events.append(stoppedEvent)
        }

        var deletedGroupIDs = try readDeletedGroupIDs(in: directory)
        let allGroups = try readLines(ShotGroup.self, from: directory.appendingPathComponent("shots.jsonl"), sessionID: sessionID)
        let groupsOnDisk = allGroups.filter { !deletedGroupIDs.contains($0.id) }

        var questionLinkedGroupIDs = Set<Int>()
        for event in events {
            if case .question(_, let shotGroupID, let earlierShotGroupIDs) = event.kind {
                questionLinkedGroupIDs.insert(shotGroupID)
                questionLinkedGroupIDs.formUnion(earlierShotGroupIDs)
            }
        }
        let selection = ScreenshotCleanup.select(shotGroups: groupsOnDisk, questionLinkedGroupIDs: questionLinkedGroupIDs)

        let shotsFolder = shotsDirectory(sessionID: sessionID)
        for group in groupsOnDisk where selection.delete.contains(group.id) {
            for shot in group.shots {
                try? fileManager.removeItem(at: shotsFolder.appendingPathComponent(shot.fileName))
            }
        }
        deletedGroupIDs.formUnion(selection.delete)
        try writeDeletedGroupIDs(deletedGroupIDs, in: directory)

        metadata.endedAt = endTime
        if let summary { metadata.summary = summary }
        metadata.cleanedUp = true

        let keptGroups = allGroups.filter { !deletedGroupIDs.contains($0.id) }
        let logText = SessionLogRenderer.render(
            metadata: metadata,
            events: events,
            shotGroups: keptGroups,
            timeZone: timeZone,
            shotLink: { shot in
                fileManager.fileExists(atPath: shotsFolder.appendingPathComponent(shot.fileName).path)
                    ? "shots/" + shot.fileName : nil
            }
        )
        try logText.write(to: directory.appendingPathComponent("log.md"), atomically: true, encoding: .utf8)
        try writeMetadata(metadata, in: directory)
        return metadata
    }

    // MARK: Read back

    /// Newest first. Folders without a readable `session.json` are skipped.
    /// Finishes every session folder a crash or force quit left without `endedAt`, except the one
    /// running now: runs the same cleanup and `log.md` as Stop, with no summary. Returns the ids it finished.
    public func finishAbandonedSessions(exceptSessionID: String?) throws -> [String] {
        guard fileManager.fileExists(atPath: locations.sessionsDirectory.path) else { return [] }
        let folders = try fileManager.contentsOfDirectory(at: locations.sessionsDirectory, includingPropertiesForKeys: nil)
        var finishedIDs: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let folderID = folder.lastPathComponent
            guard folderID != exceptSessionID,
                  let metadata = try? readMetadata(in: folder), metadata.endedAt == nil
            else { continue }
            // Read everything first: a corrupt log line skips this folder before anything is written to it.
            guard let events = try? readLines(SessionEvent.self, from: folder.appendingPathComponent("events.jsonl"), sessionID: folderID),
                  (try? readLines(ShotGroup.self, from: folder.appendingPathComponent("shots.jsonl"), sessionID: folderID)) != nil
            else { continue }
            let lastEventTime = events.map(\.time).max() ?? metadata.startedAt
            if (try? finishSession(sessionID: folderID, at: lastEventTime, summary: nil)) != nil {
                finishedIDs.append(folderID)
            }
        }
        return finishedIDs
    }

    public func listSessions() throws -> [SessionMetadata] {
        guard fileManager.fileExists(atPath: locations.sessionsDirectory.path) else { return [] }
        let folders = try fileManager.contentsOfDirectory(
            at: locations.sessionsDirectory, includingPropertiesForKeys: nil
        )
        let sessions = folders.compactMap { try? readMetadata(in: $0) }
        return sessions.sorted { left, right in
            if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
            return left.id > right.id
        }
    }

    public func loadSession(id: String) throws -> LoadedSession {
        let directory = try existingSessionDirectory(sessionID: id)
        let deletedGroupIDs = try readDeletedGroupIDs(in: directory)
        let groups = try readLines(ShotGroup.self, from: directory.appendingPathComponent("shots.jsonl"), sessionID: id)
        return LoadedSession(
            metadata: try readMetadata(in: directory),
            events: try readLines(SessionEvent.self, from: directory.appendingPathComponent("events.jsonl"), sessionID: id),
            shotGroups: groups.filter { !deletedGroupIDs.contains($0.id) }
        )
    }

    /// For the Save flow, which records where the session was saved.
    public func updateMetadata(_ metadata: SessionMetadata) throws {
        let directory = try existingSessionDirectory(sessionID: metadata.id)
        try writeMetadata(metadata, in: directory)
    }

    // MARK: Files

    private static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter().string(from: date))
        }
        // Sorted keys keep the log stable; compact output keeps one record on one line.
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = isoFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)")
                )
            }
            return date
        }
        return decoder
    }

    /// Fractional seconds keep event order exact within a second. Made fresh each time because the formatter is not Sendable.
    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func appendLine<Record: Encodable>(_ record: Record, to fileURL: URL) throws {
        var line = try Self.makeEncoder(pretty: false).encode(record)
        line.append(UInt8(ascii: "\n"))
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // Flushed to disk now, so a crash right after loses nothing.
        try handle.synchronize()
    }

    /// Reads one JSON record per line. A broken last line (a crash mid-write) is ignored; a broken earlier line throws.
    private func readLines<Record: Decodable>(_ type: Record.Type, from fileURL: URL, sessionID: String) throws -> [Record] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = Self.makeDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var records: [Record] = []
        for index in lines.indices {
            let line = lines[index]
            do {
                records.append(try decoder.decode(Record.self, from: Data(line.utf8)))
            } catch {
                if index == lines.count - 1 { break }
                throw SessionStoreError.unreadableLogLine(sessionID: sessionID, lineNumber: index + 1)
            }
        }
        return records
    }

    private func readMetadata(in directory: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        return try Self.makeDecoder().decode(SessionMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: SessionMetadata, in directory: URL) throws {
        let data = try Self.makeEncoder(pretty: true).encode(metadata)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func readDeletedGroupIDs(in directory: URL) throws -> Set<Int> {
        let fileURL = directory.appendingPathComponent("deleted-shot-groups.json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return Set(try JSONDecoder().decode([Int].self, from: Data(contentsOf: fileURL)))
    }

    private func writeDeletedGroupIDs(_ ids: Set<Int>, in directory: URL) throws {
        let data = try JSONEncoder().encode(ids.sorted())
        try data.write(to: directory.appendingPathComponent("deleted-shot-groups.json"), options: .atomic)
    }
}
