//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Multi-display screen capture through ScreenCaptureKit. Returns raw images only;
//  JPEG encoding, file names and the log live in ClickyCore and SessionScreenRecorder.
//

import AppKit
import ScreenCaptureKit

/// One display captured at one moment, before any compression.
struct CapturedDisplayImage {
    /// 1-based. Stable for a given display (main display first), so change detection can
    /// match the same display across captures even when the cursor moves between displays.
    let screenNumber: Int
    let isCursorScreen: Bool
    /// AppKit global frame (bottom-left origin), the same space as NSEvent.mouseLocation.
    let displayFrameInPoints: CGRect
    let image: CGImage
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// The long side of the images sent to the AI.
    static let sentImageLongSidePixels = 1280
    /// The long side of the small images used only to notice that the screen changed.
    static let changeDetectionLongSidePixels = 320

    /// Captures every connected display with this app's own windows (chat window, pointer
    /// overlay) left out. The result lists the cursor's display first, as the AI should treat
    /// it as the primary focus; each item still carries its stable screen number.
    static func captureAllDisplays(longSidePixels: Int) async throws -> [CapturedDisplayImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // NSEvent.mouseLocation and NSScreen.frame both use AppKit coordinates (bottom-left
        // origin), while SCDisplay.frame uses Core Graphics coordinates (top-left origin).
        // On multi-display setups the Y origins differ, so use NSScreen frames for cursor checks.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        var displayOrderByDisplayID: [CGDirectDisplayID: Int] = [:]
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[displayID] = screen
                displayOrderByDisplayID[displayID] = screenIndex
            }
        }

        // Stable numbering: NSScreen.screens lists the main display first and keeps its order.
        let displaysInStableOrder = content.displays.sorted { displayA, displayB in
            let orderA = displayOrderByDisplayID[displayA.displayID] ?? Int.max
            let orderB = displayOrderByDisplayID[displayB.displayID] ?? Int.max
            if orderA != orderB { return orderA < orderB }
            return displayA.displayID < displayB.displayID
        }

        var capturedDisplays: [CapturedDisplayImage] = []

        for (displayIndex, display) in displaysInStableOrder.enumerated() {
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = longSidePixels
                configuration.height = max(1, Int(CGFloat(longSidePixels) / aspectRatio))
            } else {
                configuration.height = longSidePixels
                configuration.width = max(1, Int(CGFloat(longSidePixels) * aspectRatio))
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            capturedDisplays.append(CapturedDisplayImage(
                screenNumber: displayIndex + 1,
                isCursorScreen: displayFrame.contains(mouseLocation),
                displayFrameInPoints: displayFrame,
                image: cgImage
            ))
        }

        // Cursor display first (stable sort keeps the rest in screen-number order).
        return capturedDisplays.enumerated().sorted { entryA, entryB in
            if entryA.element.isCursorScreen != entryB.element.isCursorScreen { return entryA.element.isCursorScreen }
            return entryA.offset < entryB.offset
        }.map { $0.element }
    }
}
