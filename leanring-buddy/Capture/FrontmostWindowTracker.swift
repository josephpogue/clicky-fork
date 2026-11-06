//
//  FrontmostWindowTracker.swift
//  leanring-buddy
//
//  Reports when the frontmost app or its top window changes. Reads only the window's
//  name from the window list (needs the screen-recording permission the session already
//  has); it never reads window contents.
//

import AppKit

@MainActor
final class FrontmostWindowTracker {

    private(set) var currentAppName: String = ""
    private(set) var currentWindowTitle: String?

    private var onFocusChanged: ((String, String?, Bool) -> Void)?
    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    /// Starts watching. The current app and window are recorded silently (read them from
    /// `currentAppName` and `currentWindowTitle`); only later changes call `onFocusChanged`
    /// with (app name, window title, isAppSwitch).
    func start(onFocusChanged: @escaping (String, String?, Bool) -> Void) {
        stop()
        self.onFocusChanged = onFocusChanged

        if let focus = readFrontmostFocus() {
            currentAppName = focus.appName
            currentWindowTitle = focus.windowTitle
        } else if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            currentAppName = frontmostApplication.localizedName ?? ""
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForFocusChange() }
        }

        // The window title can change without any app switch (new tab, new document).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForFocusChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        onFocusChanged = nil
    }

    private func checkForFocusChange() {
        // Nil when this app itself is in front (its chat window): keep the last real focus.
        guard let focus = readFrontmostFocus() else { return }

        let isAppSwitch = focus.appName != currentAppName
        let isWindowSwitch = focus.windowTitle != currentWindowTitle
        guard isAppSwitch || isWindowSwitch else { return }

        currentAppName = focus.appName
        currentWindowTitle = focus.windowTitle
        onFocusChanged?(focus.appName, focus.windowTitle, isAppSwitch)
    }

    /// The frontmost app's name and the name of its top normal window, or nil when the
    /// frontmost app is this app.
    private func readFrontmostFocus() -> (appName: String, windowTitle: String?)? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        if frontmostApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier { return nil }

        let appName = frontmostApplication.localizedName ?? frontmostApplication.bundleIdentifier ?? "Unknown app"

        // The list is ordered front to back; layer 0 is a normal app window (menus and overlays sit higher).
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for windowInfo in windowList {
            guard let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerProcessID == frontmostApplication.processIdentifier,
                  (windowInfo[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let windowName = windowInfo[kCGWindowName as String] as? String
            return (appName, (windowName?.isEmpty ?? true) ? nil : windowName)
        }
        return (appName, nil)
    }
}
