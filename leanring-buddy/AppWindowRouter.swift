//
//  AppWindowRouter.swift
//  leanring-buddy
//
//  The one place the menu bar panel asks to open the chat, sessions and
//  settings windows. Each window's controller is made the first time it is
//  asked for and kept, so the window keeps its place and its state.
//

import ClickyCore
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

    func showSessions() {
        sessionsWindowController.show()
    }

    func showSettings() {
        settingsWindowController.show()
    }

    /// Ends any `claude auth login` or `codex login` that Settings started, so quitting the app
    /// leaves no login process behind. Called from `applicationShouldTerminate`.
    func endRunningSignIns() {
        // Works from the process list, not the Settings controller, so quitting never has to build it.
        SignInProcessEnder.endAllSignIns()
    }
}
