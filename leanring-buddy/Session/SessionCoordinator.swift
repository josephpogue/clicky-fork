//
//  SessionCoordinator.swift
//  leanring-buddy
//
//  Owns one Clicky Fork session from Start to Stop: microphone, screen
//  recording, the question key, the session log and the AI provider.
//  The windows read its state and call startSession and stopSession.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()

    /// App data folders (sessions, provider sign-in folders). Honours CLICKY_DATA_DIR.
    let locations: AppDataLocations
    let sessionStore: SessionStore

    /// The chat window shows this state; the coordinator fills it during a session.
    let chatWindowState = ChatWindowState()

    @Published private(set) var isSessionRunning = false

    /// Sends a session's id once Stop has finished writing its log and cleanup.
    let sessionFinished = PassthroughSubject<String, Never>()

    private init() {
        locations = AppDataLocations.standard(environment: ProcessInfo.processInfo.environment)
        try? locations.createDirectories()
        sessionStore = SessionStore(locations: locations)
    }

    func startSession() {}

    func stopSession() {}
}
