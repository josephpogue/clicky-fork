import Foundation
import Testing
@testable import ClickyCore

/// The contracts are stored on disk by later slices, so a round trip through JSON must keep every field.
struct ContractsTests {
    @Test func sessionEventKindsSurviveAJSONRoundTrip() throws {
        let events: [SessionEventKind] = [
            .sessionStarted,
            .focusChanged(appName: "Xcode", windowTitle: nil),
            .utterance(text: "hello"),
            .questionStarted,
            .question(text: "what is this", shotGroupID: 3, earlierShotGroupIDs: [1, 2]),
            .answer(text: "a button", provider: .chatgpt, model: "m", secondsToAnswer: 1.5, pointLabel: "save"),
            .answerFailed(message: "limit", provider: .claude, model: "sonnet", usageLimitReached: true),
            .providerSwitched(from: .claude, to: .chatgpt),
            .screenshot(shotGroupID: 4),
            .sessionStopped,
        ]

        for kind in events {
            let original = SessionEvent(time: Date(timeIntervalSince1970: 1_000), kind: kind)
            let decoded = try JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(original))
            #expect(decoded == original)
        }
    }

    @Test func shotGroupKeepsItsDisplayFrameAndThumbnail() throws {
        let shot = DisplayShot(
            fileName: "0007-screen1.jpg",
            screenNumber: 1,
            isCursorScreen: true,
            pixelWidth: 1280,
            pixelHeight: 800,
            displayFrameInPoints: CGRect(x: -1440, y: 0, width: 1440, height: 900),
            thumbnail: ThumbnailSignature(width: 2, height: 2, grayscaleBytes: [0, 85, 170, 255])
        )
        let group = ShotGroup(
            id: 7,
            capturedAt: Date(timeIntervalSince1970: 2_000),
            reason: .appSwitch,
            appName: "Safari",
            windowTitle: "Docs",
            shots: [shot]
        )

        let decoded = try JSONDecoder().decode(ShotGroup.self, from: JSONEncoder().encode(group))

        #expect(decoded == group)
    }

    @Test func providerIDListsBothProviders() {
        #expect(ProviderID.allCases == [.claude, .chatgpt])
    }
}
