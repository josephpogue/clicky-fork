import Foundation
import Testing
@testable import ClickyCore

@Suite("Earlier moment picker")
struct QuestionsEarlierMomentTests {
    private typealias Fixtures = QuestionsFixtures

    private var groups: [ShotGroup] {
        [
            Fixtures.group(id: 1, capturedAt: Fixtures.time(14, 0), appName: "Safari", windowTitle: "Invoice 1042"),
            Fixtures.group(id: 2, capturedAt: Fixtures.time(14, 3), appName: "Terminal", windowTitle: "zsh"),
            Fixtures.group(id: 3, capturedAt: Fixtures.time(14, 6), appName: "Xcode", windowTitle: "Clicky"),
        ]
    }

    private func pick(_ question: String, groups overrideGroups: [ShotGroup]? = nil, now: Date? = nil) -> Int? {
        EarlierMomentPicker.pick(
            question: question,
            groups: overrideGroups ?? groups,
            now: now ?? Fixtures.time(14, 8),
            currentAppName: "Xcode",
            currentWindowTitle: "Clicky"
        )?.id
    }

    @Test func relativeTimePicksClosestGroup() {
        #expect(pick("what did that say 5 minutes ago") == 2) // target 14:03
        #expect(pick("what was on screen 3 minutes ago") == 3) // target 14:05, 14:06 is 1 min away, 14:03 is 2
    }

    @Test func relativeTimeUnderstandsWordsAndUnits() {
        #expect(pick("what was it a minute ago", now: Fixtures.time(14, 4)) == 2) // target 14:03
        #expect(pick("what was it two minutes ago") == 3) // target 14:06
        #expect(pick("what was it 30 seconds ago", now: Fixtures.time(14, 3, 40)) == 2) // target 14:03:10
        #expect(pick("what was it half an hour ago") == 1) // target 13:38, closest 14:00
    }

    @Test func nameMatchPicksLatestMatchingGroup() {
        #expect(pick("what was the total on the invoice I had open earlier") == 1)
    }

    @Test func backReferenceAloneSkipsTheCurrentView() {
        #expect(pick("what was the error before") == 2)
    }

    @Test func noBackReferenceGivesNil() {
        #expect(pick("how do I fix this") == nil)
    }

    @Test func ignoresGroupsNewerThanTwentySeconds() {
        let recent = Fixtures.group(
            id: 4, capturedAt: Fixtures.time(14, 7, 50), appName: "Mail", windowTitle: "Inbox"
        )
        // 14:07:50 is 10 s before 14:08:00, so it is not eligible
        #expect(pick("what was the error before", groups: groups + [recent]) == 2)
        #expect(pick("what was on screen 10 seconds ago", groups: groups + [recent]) == 3)
    }

    @Test func wholeWordAndCaseInsensitiveMatching() {
        #expect(pick("What WAS in the TERMINAL earlier") == 2)
        // "hadron" holds "had" but is not the word "had"; "cat" is under 4 letters
        #expect(pick("the hadron cat") == nil)
    }

    @Test func nameMatchNeedsFourLetters() {
        let tiny = [Fixtures.group(id: 1, capturedAt: Fixtures.time(14, 0), appName: "Zed", windowTitle: "zsh")]
        // "zsh" is 3 letters so rule 2 does not apply; rule 3 picks the differing group anyway
        #expect(pick("what was the zsh output", groups: tiny) == 1)
    }
}
