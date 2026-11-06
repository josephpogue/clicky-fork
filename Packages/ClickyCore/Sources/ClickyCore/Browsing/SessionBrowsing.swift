import Foundation

/// One row of the session list.
public struct SessionListEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    /// endedAt minus startedAt, 0 while the session has no end.
    public var durationSeconds: Double
    public var questionCount: Int
    public var savedProject: String?
}

public enum SessionTimelineKind: Equatable, Sendable {
    case focus, speech, question, answer, notice
}

/// One row of a session's detail.
public struct SessionTimelineEntry: Equatable, Sendable {
    public var time: Date
    public var kind: SessionTimelineKind
    public var text: String
    /// A short second line, such as "Claude, sonnet, 2.4 s".
    public var detail: String?
    public var shotFileURL: URL?
}

/// Turns a loaded session into what the session list and detail windows show, and what Save sends to the vault.
public enum SessionBrowsing {
    public static func listEntry(for session: LoadedSession, timeZone: TimeZone) -> SessionListEntry {
        let metadata = session.metadata
        let questionTexts = questionTexts(in: session)
        let title = SessionNoteTitle.make(
            summary: metadata.summary, firstQuestion: questionTexts.first, startedAt: metadata.startedAt,
            timeZone: timeZone
        ).title
        let duration = metadata.endedAt.map { $0.timeIntervalSince(metadata.startedAt) } ?? 0
        return SessionListEntry(
            id: metadata.id, title: title, startedAt: metadata.startedAt, durationSeconds: duration,
            questionCount: questionTexts.count, savedProject: metadata.savedProject)
    }

    public static func timeline(for session: LoadedSession, shotsDirectory: URL) -> [SessionTimelineEntry] {
        let groupsByID = Dictionary(session.shotGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A question's own screens are shown on the question, so its group is not a "screen changed" moment.
        let questionGroupIDs = Set(session.events.compactMap { event -> Int? in
            if case .question(_, let shotGroupID, _) = event.kind { return shotGroupID }
            return nil
        })

        func shotFileURL(forGroupID groupID: Int) -> URL? {
            guard let shot = cursorShot(in: groupsByID[groupID]) else { return nil }
            return shotsDirectory.appendingPathComponent(shot.fileName)
        }

        var entries: [SessionTimelineEntry] = []
        var lastFocusIndex: Int?
        for event in session.events {
            switch event.kind {
            case .focusChanged(let appName, let windowTitle):
                let text = windowTitle.map { "\(appName) (\($0))" } ?? appName
                entries.append(SessionTimelineEntry(time: event.time, kind: .focus, text: text))
                lastFocusIndex = entries.count - 1
            case .utterance(let text):
                entries.append(SessionTimelineEntry(time: event.time, kind: .speech, text: text))
            case .question(let text, let shotGroupID, _):
                entries.append(SessionTimelineEntry(
                    time: event.time, kind: .question, text: text, shotFileURL: shotFileURL(forGroupID: shotGroupID)))
            case .answer(let text, let provider, let model, let secondsToAnswer, _):
                let detail = "\(displayName(of: provider)), \(model), \(String(format: "%.1f", secondsToAnswer)) s"
                entries.append(SessionTimelineEntry(
                    time: event.time, kind: .answer, text: PointTagParser.parse(text).spokenText, detail: detail))
            case .answerFailed(let message, _, _, _):
                entries.append(SessionTimelineEntry(time: event.time, kind: .notice, text: message))
            case .providerSwitched(_, let to):
                entries.append(SessionTimelineEntry(
                    time: event.time, kind: .notice, text: "Switched to \(displayName(of: to))"))
            case .screenshot(let shotGroupID):
                guard !questionGroupIDs.contains(shotGroupID), let url = shotFileURL(forGroupID: shotGroupID) else { continue }
                if let focusIndex = lastFocusIndex, entries[focusIndex].shotFileURL == nil {
                    entries[focusIndex].shotFileURL = url
                } else {
                    entries.append(SessionTimelineEntry(
                        time: event.time, kind: .notice, text: "Screen changed", shotFileURL: url))
                }
            case .sessionStarted, .questionStarted, .sessionStopped:
                continue
            case .digDeeperAsked, .passagesAttached, .brainToolCalled, .answerTiming:
                continue
            }
        }
        return entries
    }

    /// Every shot file of every group a question names (its own group or an earlier one) that is still on disk,
    /// ordered by group then screen, without duplicates. These are the shots Save copies into the vault.
    public static func questionShotFileNames(for session: LoadedSession) -> [String] {
        var namedGroupIDs = Set<Int>()
        for event in session.events {
            if case .question(_, let shotGroupID, let earlierShotGroupIDs) = event.kind {
                namedGroupIDs.insert(shotGroupID)
                namedGroupIDs.formUnion(earlierShotGroupIDs)
            }
        }
        var fileNames: [String] = []
        for group in session.shotGroups.sorted(by: { $0.id < $1.id }) where namedGroupIDs.contains(group.id) {
            for shot in group.shots.sorted(by: { $0.screenNumber < $1.screenNumber }) where !fileNames.contains(shot.fileName) {
                fileNames.append(shot.fileName)
            }
        }
        return fileNames
    }

    /// The link target the saved log uses for a shot: a copied question shot sits beside the note, any other shot
    /// that is still on disk is linked by its absolute file URL, and a shot that is gone is left out.
    public static func vaultShotLink(
        stem: String, questionShotFileNames: Set<String>, shotsDirectory: URL
    ) -> (DisplayShot) -> String? {
        return { shot in
            if questionShotFileNames.contains(shot.fileName) {
                return "\(stem)/shots/\(shot.fileName)"
            }
            let fileURL = shotsDirectory.appendingPathComponent(shot.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return fileURL.absoluteString
        }
    }

    private static func questionTexts(in session: LoadedSession) -> [String] {
        session.events.compactMap { event in
            if case .question(let text, _, _) = event.kind { return text }
            return nil
        }
    }

    private static func cursorShot(in group: ShotGroup?) -> DisplayShot? {
        guard let group else { return nil }
        return group.shots.first(where: \.isCursorScreen) ?? group.shots.first
    }

    private static func displayName(of provider: ProviderID) -> String {
        switch provider {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }
}
