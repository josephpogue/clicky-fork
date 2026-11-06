import Testing
@testable import ClickyCore

struct SessionLogRendererTests {
    typealias Support = SessionLogTestSupport

    private func event(_ time: String, _ kind: SessionEventKind) -> SessionEvent {
        SessionEvent(time: Support.date("2026-11-05T\(time)-05:00"), kind: kind)
    }

    private func twoScreenGroup() -> ShotGroup {
        var group = Support.group(4, .question, app: "Safari", title: "Invoice 48213", gray: 120)
        group.shots.append(Support.uniformShot(fileName: "0004-screen2.jpg", screenNumber: 2, gray: 120))
        return group
    }

    private func sampleEvents() -> [SessionEvent] {
        [
            event("14:02:10", .sessionStarted),
            event("14:02:11", .focusChanged(appName: "Safari", windowTitle: "Invoice 48213")),
            event("14:02:11", .screenshot(shotGroupID: 1)),
            event("14:02:30", .utterance(text: "okay let me look at the total")),
            event("14:03:01", .questionStarted),
            event("14:03:01", .screenshot(shotGroupID: 4)),
            event("14:03:01", .question(text: "where do I pay this", shotGroupID: 4, earlierShotGroupIDs: [])),
            event("14:03:04", .answer(
                text: "Click the blue Pay now button at the bottom right. [POINT:1180,40:pay button]",
                provider: .claude, model: "sonnet", secondsToAnswer: 2.7, pointLabel: "pay button"
            )),
            event("14:05:00", .questionStarted),
            event("14:05:00", .answerFailed(
                message: "usage limit reached", provider: .claude, model: "sonnet", usageLimitReached: true
            )),
            event("14:05:10", .providerSwitched(from: .claude, to: .chatgpt)),
            event("14:47:31", .sessionStopped),
        ]
    }

    private func sampleMetadata(summary: String? = "Worked on the invoice in Safari and asked where to pay.") -> SessionMetadata {
        SessionMetadata(
            id: "2026-11-05-140210",
            startedAt: Support.date("2026-11-05T14:02:10-05:00"),
            endedAt: Support.date("2026-11-05T14:47:31-05:00"),
            summary: summary,
            cleanedUp: true
        )
    }

    private func sampleGroups() -> [ShotGroup] {
        [
            Support.group(1, .appSwitch, app: "Safari", title: "Invoice 48213", gray: 100),
            twoScreenGroup(),
        ]
    }

    private func defaultLink(_ shot: DisplayShot) -> String? { "shots/" + shot.fileName }

    @Test func renderedLogMatchesTheDesignSampleExactly() {
        let expected = """
        # Session 2026-11-05 14:02 to 14:47

        **Summary:** Worked on the invoice in Safari and asked where to pay.

        Started 14:02:10. Ended 14:47:31. 2 questions. Models: Claude sonnet.

        ## Timeline

        - 14:02:10 Session started.
        - 14:02:11 Safari, "Invoice 48213". ![screen 1](shots/0001-screen1.jpg)
        - 14:02:30 Said: "okay let me look at the total"
        - 14:03:01 **Question:** "where do I pay this" ![screen 1](shots/0004-screen1.jpg) ![screen 2](shots/0004-screen2.jpg)
        - 14:03:04 **Answer** (Claude, sonnet, 2.7 s): Click the blue Pay now button at the bottom right. Pointed at: pay button.
        - 14:05:00 Answer failed (Claude, sonnet): usage limit reached.
        - 14:05:10 Switched from Claude to ChatGPT.
        - 14:47:31 Session stopped.

        """

        let rendered = SessionLogRenderer.render(
            metadata: sampleMetadata(),
            events: sampleEvents(),
            shotGroups: sampleGroups(),
            timeZone: Support.newYork,
            shotLink: defaultLink
        )

        #expect(rendered == expected)
    }

    @Test func summaryEndedAndModelsLeaveTheirPartsOutWhenAbsent() {
        var metadata = sampleMetadata(summary: nil)
        metadata.endedAt = nil

        let rendered = SessionLogRenderer.render(
            metadata: metadata,
            events: [event("14:02:10", .sessionStarted)],
            shotGroups: [],
            timeZone: Support.newYork,
            shotLink: defaultLink
        )

        #expect(rendered.hasPrefix("# Session 2026-11-05 14:02\n\nStarted 14:02:10. 0 questions.\n\n## Timeline\n"))
        #expect(!rendered.contains("Summary"))
        #expect(!rendered.contains("Ended"))
        #expect(!rendered.contains("Models"))
    }

    @Test func screenChangeLinesShowTheirImagesAndDropWhenCleanupDeletedThem() {
        let kept = Support.group(2, .screenChange, app: "Safari", title: "A", gray: 100)
        let events = [
            event("14:10:00", .screenshot(shotGroupID: 2)),
            event("14:11:00", .screenshot(shotGroupID: 3)), // group 3 was deleted by cleanup
        ]

        let rendered = SessionLogRenderer.render(
            metadata: sampleMetadata(),
            events: events,
            shotGroups: [kept],
            timeZone: Support.newYork,
            shotLink: defaultLink
        )

        #expect(rendered.contains("- 14:10:00 Screen changed. ![screen 1](shots/0002-screen1.jpg)\n"))
        #expect(!rendered.contains("14:11:00"))
    }

    @Test func aShotWithNoLinkIsLeftOutAndAFocusLineWithoutATitleHasNone() {
        let events = [
            event("14:02:11", .focusChanged(appName: "Finder", windowTitle: nil)),
            event("14:02:11", .screenshot(shotGroupID: 1)),
        ]

        let rendered = SessionLogRenderer.render(
            metadata: sampleMetadata(),
            events: events,
            shotGroups: [Support.group(1, .appSwitch, app: "Finder", title: nil, gray: 100)],
            timeZone: Support.newYork,
            shotLink: { _ in nil }
        )

        #expect(rendered.contains("- 14:02:11 Finder.\n"))
        #expect(!rendered.contains("Screen changed"))
    }
}
