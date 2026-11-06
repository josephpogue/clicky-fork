import Testing
@testable import ClickyCore

struct SessionLogCleanupTests {
    typealias Support = SessionLogTestSupport

    @Test func cleanupKeepsQuestionsFirstOfVisitAndBigChangesAndDeletesNearDuplicates() {
        // Differences are |a-b|/255 with the threshold at 0.10 (25.5 gray levels).
        // 2: |120-100|/255 = 0.078 from kept 1, below 0.10, delete.
        // 3: |160-100|/255 = 0.235 from kept 1, keep.
        // 4: question, keep. 5: |170-161|/255 = 0.035 from kept 4, delete.
        // 6: first of the Xcode visit, keep. 7: linked to a question, keep.
        // 8: first of a new Safari visit, keep.
        let groups = [
            Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100),
            Support.group(2, .screenChange, app: "Safari", title: "A", gray: 120),
            Support.group(3, .screenChange, app: "Safari", title: "A", gray: 160),
            Support.group(4, .question, app: "Safari", title: "A", gray: 161),
            Support.group(5, .screenChange, app: "Safari", title: "A", gray: 170),
            Support.group(6, .appSwitch, app: "Xcode", title: "B", gray: 170),
            Support.group(7, .screenChange, app: "Xcode", title: "B", gray: 175),
            Support.group(8, .windowSwitch, app: "Safari", title: "A", gray: 100),
        ]

        let result = ScreenshotCleanup.select(shotGroups: groups, questionLinkedGroupIDs: [7])

        #expect(result.keep == [1, 3, 4, 6, 7, 8])
        #expect(result.delete == [2, 5])
    }

    @Test func groupsAreJudgedInTimeOrderNoMatterHowTheyAreListed() {
        let groups = [
            Support.group(3, .screenChange, app: "Safari", title: "A", gray: 160),
            Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100),
            Support.group(2, .screenChange, app: "Safari", title: "A", gray: 120),
        ]

        let result = ScreenshotCleanup.select(shotGroups: groups, questionLinkedGroupIDs: [])

        #expect(result.keep == [1, 3])
        #expect(result.delete == [2])
    }

    @Test func aGroupWithADifferentDisplayCountOrWindowTitleIsNeverTreatedAsADuplicate() {
        let single = Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100)
        var twoDisplays = Support.group(2, .screenChange, app: "Safari", title: "A", gray: 100)
        twoDisplays.shots.append(Support.uniformShot(fileName: "0002-screen2.jpg", screenNumber: 2, gray: 100))
        // Identical pixels but a different display count counts as a difference of 1.0.
        let result = ScreenshotCleanup.select(shotGroups: [single, twoDisplays], questionLinkedGroupIDs: [])
        #expect(result.keep == [1, 2])

        // Same pixels, new window title: a new visit, so its first group stays.
        let retitled = Support.group(2, .screenChange, app: "Safari", title: "Other", gray: 100)
        let retitledResult = ScreenshotCleanup.select(shotGroups: [single, retitled], questionLinkedGroupIDs: [])
        #expect(retitledResult.keep == [1, 2])
    }

    @Test func theLargestChangeAcrossDisplaysDecides() {
        var first = Support.group(1, .sessionStart, app: "Safari", title: "A", gray: 100)
        first.shots.append(Support.uniformShot(fileName: "0001-screen2.jpg", screenNumber: 2, gray: 100))
        var second = Support.group(2, .screenChange, app: "Safari", title: "A", gray: 100)
        // Screen 2 moves by 50/255 = 0.196 while screen 1 is unchanged: keep.
        second.shots.append(Support.uniformShot(fileName: "0002-screen2.jpg", screenNumber: 2, gray: 150))

        let result = ScreenshotCleanup.select(shotGroups: [first, second], questionLinkedGroupIDs: [])

        #expect(result.keep == [1, 2])
        #expect(result.delete.isEmpty)
    }
}
