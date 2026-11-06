import Foundation
@testable import ClickyCore

/// Shared builders for the session log tests.
enum SessionLogTestSupport {
    /// Parses "2026-11-05T14:02:10-05:00" style text.
    static func date(_ isoText: String) -> Date {
        ISO8601DateFormatter().date(from: isoText)!
    }

    static let newYork = TimeZone(identifier: "America/New_York")!

    /// A one-display shot whose thumbnail is a single uniform gray value, so a difference is |a-b|/255.
    static func uniformShot(fileName: String, screenNumber: Int = 1, gray: UInt8) -> DisplayShot {
        DisplayShot(
            fileName: fileName,
            screenNumber: screenNumber,
            isCursorScreen: screenNumber == 1,
            pixelWidth: 1280,
            pixelHeight: 800,
            displayFrameInPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            thumbnail: ThumbnailSignature(width: 2, height: 2, grayscaleBytes: [gray, gray, gray, gray])
        )
    }

    static func group(
        _ id: Int,
        _ reason: ShotReason,
        app: String,
        title: String?,
        gray: UInt8,
        at capturedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> ShotGroup {
        let paddedID = String(format: "%04d", id)
        return ShotGroup(
            id: id,
            capturedAt: capturedAt.addingTimeInterval(Double(id)),
            reason: reason,
            appName: app,
            windowTitle: title,
            shots: [uniformShot(fileName: "\(paddedID)-screen1.jpg", gray: gray)]
        )
    }

    static func temporaryLocations() -> AppDataLocations {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-sessionlog-tests-\(UUID().uuidString)", isDirectory: true)
        return AppDataLocations(root: root)
    }
}
