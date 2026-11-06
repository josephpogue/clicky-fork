import CoreGraphics
import Foundation

/// Why a group of screenshots was taken. Kept in the log so the session list can explain each moment.
public enum ShotReason: String, Codable, Sendable {
    case sessionStart, question, appSwitch, windowSwitch, screenChange
}

/// A tiny grayscale copy of one display, kept beside each screenshot so change detection and cleanup never decode JPEGs.
public struct ThumbnailSignature: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// width * height values, row-major, 0...255
    public var grayscaleBytes: [UInt8]

    public init(width: Int, height: Int, grayscaleBytes: [UInt8]) {
        self.width = width
        self.height = height
        self.grayscaleBytes = grayscaleBytes
    }
}

/// One saved screenshot of one display. Holds everything needed to send it and to map a POINT tag back onto the real screen.
public struct DisplayShot: Codable, Equatable, Sendable {
    /// Inside the session's shots/ folder, e.g. "0007-screen1.jpg"
    public var fileName: String
    /// 1-based, the same number the AI sees as "screen1"
    public var screenNumber: Int
    public var isCursorScreen: Bool
    /// Size of the saved (and sent) image
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// AppKit global frame of that display, to map POINT tags back
    public var displayFrameInPoints: CGRect
    public var thumbnail: ThumbnailSignature

    public init(
        fileName: String,
        screenNumber: Int,
        isCursorScreen: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        displayFrameInPoints: CGRect,
        thumbnail: ThumbnailSignature
    ) {
        self.fileName = fileName
        self.screenNumber = screenNumber
        self.isCursorScreen = isCursorScreen
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayFrameInPoints = displayFrameInPoints
        self.thumbnail = thumbnail
    }
}

/// All displays captured at one moment. Questions and log events point at a group by its id.
public struct ShotGroup: Codable, Equatable, Sendable, Identifiable {
    /// 1-based sequence within the session
    public var id: Int
    public var capturedAt: Date
    public var reason: ShotReason
    public var appName: String
    public var windowTitle: String?
    /// One per display
    public var shots: [DisplayShot]

    public init(
        id: Int,
        capturedAt: Date,
        reason: ShotReason,
        appName: String,
        windowTitle: String?,
        shots: [DisplayShot]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.reason = reason
        self.appName = appName
        self.windowTitle = windowTitle
        self.shots = shots
    }
}
