//
//  AppWindowRouter.swift
//  leanring-buddy
//
//  The one place the menu bar panel asks to open the chat, sessions and
//  settings windows. Each window's controller is made the first time it is
//  asked for and kept, so the window keeps its place and its state.
//

import ClickyCore
import AppKit
import Foundation

@MainActor
final class AppWindowRouter {
    static let shared = AppWindowRouter()

    private lazy var chatPanelController = ChatPanelController()
    private lazy var sessionsWindowController = SessionsWindowController()
    private lazy var settingsWindowController = SettingsWindowController()

    private init() {}

    func showChat() {
        chatPanelController.show()
    }

    /// The chat key: opens the chat panel, or closes it when it is open. Never takes keyboard focus.
    func toggleChat() {
        chatPanelController.show()
    }

    func showSessions() {
        sessionsWindowController.show()
    }

    func showSettings() {
        settingsWindowController.show()
    }

    /// Moves a window the app is about to show so it does not sit under the floating chat panel. When the
    /// screen has room for only one of them the window wins and the panel drops behind it. `desiredContentSize`
    /// is the size the window was made for; the window is shrunk to the visible screen when that is too big.
    func placeOpenedWindow(_ window: NSWindow, desiredContentSize: CGSize) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let result = WindowPlacement.place(
            desiredContentSize: desiredContentSize, windowChromeHeight: chromeHeight,
            visibleFrame: visibleFrame, chatPanelFrame: chatPanelController.frameWhileVisible)
        window.setFrame(result.windowFrame, display: false)
        if result.chatPanelMustSitBehind {
            chatPanelController.sitBehind(window)
        } else {
            chatPanelController.floatAboveWindows()
        }
    }

    /// Ends any `claude auth login` or `codex login` that Settings started, so quitting the app
    /// leaves no login process behind. Called from `applicationShouldTerminate`.
    func endRunningSignIns() {
        // Works from the process list, not the Settings controller, so quitting never has to build it.
        SignInProcessEnder.endAllSignIns()
    }
}
