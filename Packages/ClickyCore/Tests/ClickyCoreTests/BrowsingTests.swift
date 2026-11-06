import Foundation
import Testing
@testable import ClickyCore

/// The fixture session from the windows brief:
/// 14:00:00 start, 14:00:01 focus Safari "Invoice 1042" + screenshot group 1, 14:01:00 utterance,
/// 14:01:30 question started, 14:02:00 question (group 2, earlier [1]), 14:02:03 answer,
/// 14:03:00 focus Terminal "zsh" + screenshot group 3, 14:04:00 answerFailed,
/// 14:04:30 providerSwitched, 14:05:00 stop. Groups 1 to 3 each hold one shot.
struct BrowsingTests {
    private let timeZone = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let shotsDirectory = URL(fileURLWithPath: "/tmp/browsing-fixture/shots", isDirectory: true)

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func group(_ id: Int, reason: ShotReason, extraNonCursorShot: Bool = false) -> ShotGroup {
        func shot(screen: Int, isCursor: Bool) -> DisplayShot {
            DisplayShot(
                fileName: ShotFileNaming.fileName(groupID: id, screenNumber: screen), screenNumber: screen,
                isCursorScreen: isCursor, pixelWidth: 1280, pixelHeight: 800,
                displayFrameInPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
                thumbnail: ThumbnailSignature(width: 1, height: 1, grayscaleBytes: [0]))
        }
        var shots = [shot(screen: 1, isCursor: !extraNonCursorShot)]
        if extraNonCursorShot { shots.append(shot(screen: 2, isCursor: true)) }
        return ShotGroup(id: id, capturedAt: at(0), reason: reason, appName: "App", windowTitle: nil, shots: shots)
    }

    private func fixtureSession(
        groups: [ShotGroup]? = nil, savedProject: String? = nil, summary: String? = nil
    ) -> LoadedSession {
        let events: [SessionEvent] = [
            SessionEvent(time: at(0), kind: .sessionStarted),
            SessionEvent(time: at(1), kind: .focusChanged(appName: "Safari", windowTitle: "Invoice 1042")),
            SessionEvent(time: at(1), kind: .screenshot(shotGroupID: 1)),
            SessionEvent(time: at(60), kind: .utterance(text: "ok")),
            SessionEvent(time: at(90), kind: .questionStarted),
            SessionEvent(time: at(120), kind: .question(text: "what is the total", shotGroupID: 2, earlierShotGroupIDs: [1])),
            SessionEvent(time: at(123), kind: .answer(
                text: "The total is 42 dollars. [POINT:640,400:total:screen1]", provider: .claude,
                model: "sonnet", secondsToAnswer: 2.43, pointLabel: "total")),
            SessionEvent(time: at(180), kind: .focusChanged(appName: "Terminal", windowTitle: "zsh")),
            SessionEvent(time: at(180), kind: .screenshot(shotGroupID: 3)),
            SessionEvent(time: at(240), kind: .answerFailed(
                message: "You've hit your limit", provider: .claude, model: "sonnet", usageLimitReached: true)),
            SessionEvent(time: at(270), kind: .providerSwitched(from: .claude, to: .chatgpt)),
            SessionEvent(time: at(300), kind: .sessionStopped),
        ]
        return LoadedSession(
            metadata: SessionMetadata(
                id: "2023-11-14-140000", startedAt: at(0), endedAt: at(300), summary: summary,
                savedProject: savedProject),
            events: events,
            shotGroups: groups ?? [
                group(1, reason: .sessionStart), group(2, reason: .question), group(3, reason: .appSwitch),
            ])
    }

    @Test func listEntryHasTitleDurationAndQuestionCount() {
        let entry = SessionBrowsing.listEntry(for: fixtureSession(savedProject: "homelab"), timeZone: timeZone)
        #expect(entry.id == "2023-11-14-140000")
        #expect(entry.title == "what is the total")
        #expect(entry.questionCount == 1)
        #expect(entry.durationSeconds == 300)  // endedAt 14:05:00 minus startedAt 14:00:00
        #expect(entry.savedProject == "homelab")
        #expect(entry.startedAt == start)
    }

    @Test func listEntryPrefersTheSummaryForTheTitleAndIsZeroLongWhenNotEnded() {
        var session = fixtureSession(summary: "Checked an invoice total. More words follow.")
        session.metadata.endedAt = nil
        let entry = SessionBrowsing.listEntry(for: session, timeZone: timeZone)
        #expect(entry.title == "Checked an invoice total")
        #expect(entry.durationSeconds == 0)
    }

    @Test func timelineListsSevenEntriesInOrder() {
        let timeline = SessionBrowsing.timeline(for: fixtureSession(), shotsDirectory: shotsDirectory)
        #expect(timeline.map(\.kind) == [.focus, .speech, .question, .answer, .focus, .notice, .notice])
        #expect(timeline.map(\.text) == [
            "Safari (Invoice 1042)", "ok", "what is the total", "The total is 42 dollars.",
            "Terminal (zsh)", "You've hit your limit", "Switched to ChatGPT",
        ])
    }

    @Test func timelineAnswerDetailNamesProviderModelAndSeconds() {
        let answer = SessionBrowsing.timeline(for: fixtureSession(), shotsDirectory: shotsDirectory)[3]
        #expect(answer.detail == "Claude, sonnet, 2.4 s")  // 2.43 rounds to 2.4
    }

    @Test func timelineAttachesShotsToFocusAndQuestionEntries() {
        let timeline = SessionBrowsing.timeline(for: fixtureSession(), shotsDirectory: shotsDirectory)
        #expect(timeline[0].shotFileURL == shotsDirectory.appendingPathComponent("0001-screen1.jpg"))
        #expect(timeline[2].shotFileURL == shotsDirectory.appendingPathComponent("0002-screen1.jpg"))
        #expect(timeline[4].shotFileURL == shotsDirectory.appendingPathComponent("0003-screen1.jpg"))
        #expect(timeline[1].shotFileURL == nil)
    }

    @Test func timelineUsesTheCursorScreenShot() {
        let groups = [group(1, reason: .sessionStart, extraNonCursorShot: true), group(2, reason: .question), group(3, reason: .appSwitch)]
        let timeline = SessionBrowsing.timeline(for: fixtureSession(groups: groups), shotsDirectory: shotsDirectory)
        #expect(timeline[0].shotFileURL == shotsDirectory.appendingPathComponent("0001-screen2.jpg"))
    }

    @Test func timelineDropsShotsWhoseGroupIsGone() {
        let groups = [group(2, reason: .question)]
        let timeline = SessionBrowsing.timeline(for: fixtureSession(groups: groups), shotsDirectory: shotsDirectory)
        #expect(timeline.map(\.kind) == [.focus, .speech, .question, .answer, .focus, .notice, .notice])
        #expect(timeline[0].shotFileURL == nil)
        #expect(timeline[4].shotFileURL == nil)
        #expect(timeline[2].shotFileURL != nil)
    }

    @Test func aSecondScreenshotAfterAFocusThatHasOneBecomesItsOwnNotice() {
        var session = fixtureSession()
        // Another screen change at 14:03:30, while the Terminal focus entry already holds group 3's shot.
        session.events.insert(SessionEvent(time: at(210), kind: .screenshot(shotGroupID: 4)), at: 9)
        session.shotGroups.append(group(4, reason: .screenChange))
        let timeline = SessionBrowsing.timeline(for: session, shotsDirectory: shotsDirectory)
        #expect(timeline.count == 8)
        #expect(timeline[5].kind == .notice)
        #expect(timeline[5].text == "Screen changed")
        #expect(timeline[5].shotFileURL == shotsDirectory.appendingPathComponent("0004-screen1.jpg"))
    }

    @Test func questionShotFileNamesCoverTheQuestionGroupAndEarlierGroups() {
        #expect(SessionBrowsing.questionShotFileNames(for: fixtureSession()) == ["0001-screen1.jpg", "0002-screen1.jpg"])
    }

    @Test func questionShotFileNamesSkipGroupsThatAreGone() {
        let session = fixtureSession(groups: [group(2, reason: .question)])
        #expect(SessionBrowsing.questionShotFileNames(for: session) == ["0002-screen1.jpg"])
    }

    @Test func vaultShotLinkPointsQuestionShotsIntoTheNoteFolderAndOthersAtTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("browsing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("0003-screen1.jpg"))

        let link = SessionBrowsing.vaultShotLink(
            stem: "2023-11-14-what-is-the-total", questionShotFileNames: ["0001-screen1.jpg", "0002-screen1.jpg"],
            shotsDirectory: folder)
        let questionShot = group(2, reason: .question).shots[0]
        let onDiskShot = group(3, reason: .appSwitch).shots[0]
        let missingShot = group(9, reason: .appSwitch).shots[0]
        #expect(link(questionShot) == "2023-11-14-what-is-the-total/shots/0002-screen1.jpg")
        #expect(link(onDiskShot) == folder.appendingPathComponent("0003-screen1.jpg").absoluteString)
        #expect(link(onDiskShot)?.hasPrefix("file://") == true)
        #expect(link(missingShot) == nil)
    }
}
