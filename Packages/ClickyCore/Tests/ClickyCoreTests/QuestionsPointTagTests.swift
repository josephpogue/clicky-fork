import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

@Suite("Point tag parser")
struct QuestionsPointTagParserTests {
    @Test func removesTagsFromBothACorrectionPartAndTheEnd() {
        let result = PointTagParser.parse("Open Gear. [POINT:1,2:gear:screen1] Correction: it is Menu. [POINT:3,4:menu:screen1]")
        #expect(result.spokenText == "Open Gear. Correction: it is Menu.")
        #expect(result.coordinate == CGPoint(x: 3, y: 4))
    }

    @Test func parsesTagWithLabelAndScreen() {
        let result = PointTagParser.parse("Click Save. [POINT:1180,40:save button:screen2]")
        #expect(result.spokenText == "Click Save.")
        #expect(result.coordinate == CGPoint(x: 1180, y: 40))
        #expect(result.label == "save button")
        #expect(result.screenNumber == 2)
    }

    @Test func parsesTagWithoutScreen() {
        let result = PointTagParser.parse("It is up there. [POINT:285,11:source control]")
        #expect(result.spokenText == "It is up there.")
        #expect(result.coordinate == CGPoint(x: 285, y: 11))
        #expect(result.label == "source control")
        #expect(result.screenNumber == nil)
    }

    @Test func noneTagGivesNoCoordinate() {
        let result = PointTagParser.parse("No spot. [POINT:none]")
        #expect(result.spokenText == "No spot.")
        #expect(result.coordinate == nil)
        #expect(result.screenNumber == nil)
    }

    @Test func tagInTheMiddleIsPointedAtAndRemovedFromTheShownText() {
        let result = PointTagParser.parse("Look at [POINT:10,20:thing] and then keep reading.")
        #expect(result.coordinate == CGPoint(x: 10, y: 20))
        #expect(result.label == "thing")
        #expect(result.spokenText == "Look at and then keep reading.")
    }

    @Test func tagFollowedByAFullStopShowsNoRawTagText() {
        let result = PointTagParser.parse("Click Save. [POINT:1180,40:save button:screen1].")
        #expect(result.spokenText == "Click Save.")
        #expect(result.coordinate == CGPoint(x: 1180, y: 40))
        #expect(result.screenNumber == 1)
        #expect(result.label == "save button")
    }

    @Test func noneTagFollowedByAFullStopIsRemoved() {
        let result = PointTagParser.parse("Here. [POINT:none].")
        #expect(result.spokenText == "Here.")
        #expect(result.coordinate == nil)
        #expect(result.label == "none")
    }

    @Test func spaceAfterPointColonIsAccepted() {
        let result = PointTagParser.parse("Here. [POINT: none]")
        #expect(result.spokenText == "Here.")
        #expect(result.coordinate == nil)
        let spaced = PointTagParser.parse("There. [POINT: 5, 6: spot]")
        #expect(spaced.coordinate == CGPoint(x: 5, y: 6))
        #expect(spaced.label == "spot")
    }

    @Test func decimalCoordinatesRoundToTheNearestPixel() {
        // 10.6 rounds to 11, 20.4 rounds to 20
        let result = PointTagParser.parse("[POINT:10.6,20.4:x:screen2] Then wait.")
        #expect(result.spokenText == "Then wait.")
        #expect(result.coordinate == CGPoint(x: 11, y: 20))
        #expect(result.screenNumber == 2)
        #expect(result.label == "x")
    }

    @Test func aLabelWithAColonKeepsTheWholeLabel() {
        let result = PointTagParser.parse("Open it. [POINT:30,40:File: Save As:screen2]")
        #expect(result.spokenText == "Open it.")
        #expect(result.label == "File: Save As")
        #expect(result.screenNumber == 2)
        #expect(result.coordinate == CGPoint(x: 30, y: 40))
    }

    @Test func aTagThenAnotherSentenceKeepsTheSentence() {
        let result = PointTagParser.parse("Click Save. [POINT:1,2:save] Then wait.")
        #expect(result.spokenText == "Click Save. Then wait.")
        #expect(result.coordinate == CGPoint(x: 1, y: 2))
    }

    @Test func theLastWellFormedTagWinsAndEveryTagIsRemoved() {
        let result = PointTagParser.parse("A [POINT:1,2:first] B [POINT:broken] C [POINT:3,4:second]")
        #expect(result.coordinate == CGPoint(x: 3, y: 4))
        #expect(result.label == "second")
        #expect(result.spokenText == "A B C")
    }

    @Test func aMalformedTagIsRemovedWithoutAPoint() {
        let result = PointTagParser.parse("Done. [POINT:left,top]")
        #expect(result.spokenText == "Done.")
        #expect(result.coordinate == nil)
    }

    @Test func aReplyOfOnlyATagHasNoShownText() {
        let result = PointTagParser.parse("[POINT:none]")
        #expect(result.spokenText == "")
    }

    @Test func textWithoutTagIsUnchanged() {
        let result = PointTagParser.parse("Just an answer.")
        #expect(result.spokenText == "Just an answer.")
        #expect(result.coordinate == nil)
        #expect(result.label == nil)
    }

    @Test func trailingWhitespaceAfterTagIsAllowed() {
        let result = PointTagParser.parse("Here. [POINT:5,6:spot]\n")
        #expect(result.coordinate == CGPoint(x: 5, y: 6))
    }
}

@Suite("Point mapper")
struct QuestionsPointMapperTests {
    private typealias Fixtures = QuestionsFixtures

    private func tag(_ x: Double, _ y: Double, screen: Int?) -> PointTagParseResult {
        PointTagParseResult(
            spokenText: "x", coordinate: CGPoint(x: x, y: y), label: "thing", screenNumber: screen
        )
    }

    @Test func mapsCenterOfOnlyDisplay() throws {
        // 640/1280 * 1440 = 720; local y 400/800 * 900 = 450; appKitY = 900 - 450 = 450
        let shot = Fixtures.shot()
        let mapped = try #require(PointMapper.globalPoint(for: tag(640, 400, screen: nil), shots: [shot]))
        #expect(mapped.point == CGPoint(x: 720, y: 450))
        #expect(mapped.shot == shot)
    }

    private var twoDisplays: [DisplayShot] {
        [
            Fixtures.shot(screenNumber: 1, isCursorScreen: true),
            Fixtures.shot(
                fileName: "0001-screen2.jpg", screenNumber: 2, isCursorScreen: false,
                pixelWidth: 1280, pixelHeight: 720,
                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            ),
        ]
    }

    @Test func mapsOnSecondDisplay() throws {
        // scale 1920/1280 = 1.5: local (480, 540); appKitY = 1080 - 540 = 540; x = 480 + 1440 = 1920
        let mapped = try #require(PointMapper.globalPoint(for: tag(320, 360, screen: 2), shots: twoDisplays))
        #expect(mapped.point == CGPoint(x: 1920, y: 540))
        #expect(mapped.shot.screenNumber == 2)
    }

    @Test func clampsOutsideImage() throws {
        // x 1400 -> 1280, y -20 -> 0; local (1920, 0); appKitY = 1080; x = 1920 + 1440 = 3360
        let mapped = try #require(PointMapper.globalPoint(for: tag(1400, -20, screen: 2), shots: twoDisplays))
        #expect(mapped.point == CGPoint(x: 3360, y: 1080))
    }

    @Test func unknownScreenFallsBackToCursorScreen() throws {
        let mapped = try #require(PointMapper.globalPoint(for: tag(640, 400, screen: 5), shots: twoDisplays))
        #expect(mapped.shot.screenNumber == 1)
        #expect(mapped.point == CGPoint(x: 720, y: 450))
    }

    @Test func noCoordinateGivesNil() {
        let none = PointTagParseResult(spokenText: "x", coordinate: nil, label: nil, screenNumber: nil)
        #expect(PointMapper.globalPoint(for: none, shots: twoDisplays) == nil)
    }
}
