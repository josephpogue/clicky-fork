//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window: just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with the session controls.
//

import ClickyCore
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel. It starts no
/// session, no capture and no login item; a session starts only from the panel.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preview rendering runs first and exits before any permission request.
        renderUIPreviewsAndExitIfRequested()

        print("Clicky Fork: starting")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Loading the speech model reads no audio; a session starts only from the panel.
        SessionCoordinator.shared.prepareSpeech()
        // Finish any session folder an earlier crash left open, off the main actor; Start waits for it.
        SessionCoordinator.shared.finishAbandonedSessionsAtLaunch()
        // Brings the brain index up to date for the Settings folders, off the main thread; an empty list does nothing.
        BrainIndexService.shared.refreshInBackground()
        // Auto-open the panel when permissions are missing so the user sees what to grant.
        if !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
    }

    /// Quitting in any phase but idle waits for the session work: a Start is cancelled, a running session
    /// stops without the summary, and a Stop in progress finishes with its summary skipped. Sign-in processes
    /// Settings started always end.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppWindowRouter.shared.endRunningSignIns()
        let quitDecision = SessionCoordinator.shared.requestQuit()
        switch quitDecision {
        case .terminateNow:
            return .terminateNow
        case .alreadyHandled:
            // The first quit request is already doing the work and will reply when it is done.
            return .terminateLater
        case .cancelStartThenTerminate, .stopWithoutSummaryThenTerminate, .skipSummaryAndWaitForStopThenTerminate:
            Task { @MainActor in
                await SessionCoordinator.shared.carryOutQuit(quitDecision)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// When launched as `Clicky Fork --render-ui-previews <directory>`, writes
    /// the preview PNGs into that directory and exits, so screens can be checked
    /// without opening the app or asking for any permission.
    private func renderUIPreviewsAndExitIfRequested() {
        let launchArguments = CommandLine.arguments
        guard let flagIndex = launchArguments.firstIndex(of: "--render-ui-previews") else { return }
        guard flagIndex + 1 < launchArguments.count else {
            print("--render-ui-previews needs a folder path")
            exit(1)
        }
        let outputDirectory = URL(fileURLWithPath: launchArguments[flagIndex + 1], isDirectory: true)
        do {
            try UIPreviewRendering.renderAll(into: outputDirectory)
            exit(0)
        } catch {
            print("Rendering UI previews failed: \(error)")
            exit(1)
        }
    }
}
