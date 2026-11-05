//
//  AppWindowRouter.swift
//  leanring-buddy
//
//  The one place the menu bar panel asks to open the chat, sessions and
//  settings windows. Later slices replace the prints with real windows.
//

import Foundation

@MainActor
final class AppWindowRouter {
    static let shared = AppWindowRouter()

    private init() {}

    func showChat() {
        print("AppWindowRouter: showChat")
    }

    func showSessions() {
        print("AppWindowRouter: showSessions")
    }

    func showSettings() {
        print("AppWindowRouter: showSettings")
    }
}
