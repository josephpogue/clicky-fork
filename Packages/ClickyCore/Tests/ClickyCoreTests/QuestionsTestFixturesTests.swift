import CoreGraphics
import Foundation
@testable import ClickyCore

/// Shared builders for the Questions suites. Holds no tests itself.
enum QuestionsFixtures {
    static let utc = TimeZone(identifier: "UTC")!

    /// 2026-11-05 at the given UTC clock time
    static func time(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: hour, minute: minute, second: second
        ))!
    }

    static func shot(
        fileName: String = "0001-screen1.jpg",
        screenNumber: Int = 1,
        isCursorScreen: Bool = true,
        pixelWidth: Int = 1280,
        pixelHeight: Int = 800,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> DisplayShot {
        DisplayShot(
            fileName: fileName,
            screenNumber: screenNumber,
            isCursorScreen: isCursorScreen,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayFrameInPoints: frame,
            thumbnail: ThumbnailSignature(width: 1, height: 1, grayscaleBytes: [0])
        )
    }

    static func group(
        id: Int,
        capturedAt: Date,
        appName: String,
        windowTitle: String?,
        shots: [DisplayShot]? = nil
    ) -> ShotGroup {
        ShotGroup(
            id: id,
            capturedAt: capturedAt,
            reason: .question,
            appName: appName,
            windowTitle: windowTitle,
            shots: shots ?? [shot(fileName: "\(id)-screen1.jpg")]
        )
    }
}
