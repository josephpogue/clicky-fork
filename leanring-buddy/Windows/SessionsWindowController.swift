//
//  SessionsWindowController.swift
//  leanring-buddy
//
//  The session list window, newest first. Opening a row opens that session's
//  detail window. The list reloads when the window opens and whenever a
//  session finishes.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class SessionListModel: ObservableObject {
    @Published var items: [SessionListItem] = []
}

private struct SessionListHost: View {
    @ObservedObject var model: SessionListModel
    let onOpen: (String) -> Void
    let onStartSession: () -> Void

    var body: some View {
        SessionListView(items: model.items, onOpen: onOpen, onStartSession: onStartSession)
    }
}

@MainActor
final class SessionsWindowController {
    private static let contentSize = CGSize(width: 460, height: 420)

    private let coordinator = SessionCoordinator.shared
    private let model = SessionListModel()
    private let timeZone = TimeZone.current
    private var window: NSWindow?
    private var detailControllers: [String: SessionDetailWindowController] = [:]
    /// Sessions whose detail window is still loading, so a second click on the same row does not open a second window.
    private var detailOpensInFlight: Set<String> = []
    private var finishedSubscription: AnyCancellable?

    init() {
        finishedSubscription = coordinator.sessionFinished
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    func show() {
        if window == nil {
            let newWindow = WindowHosting.makeStandardWindow(
                title: "Sessions", contentSize: Self.contentSize, isResizable: true, identifier: "sessions.nswindow")
            newWindow.contentMinSize = CGSize(width: 380, height: 300)
            newWindow.contentView = WindowHosting.makeHostingView(
                rootView: SessionListHost(
                    model: model,
                    onOpen: { [weak self] sessionID in self?.openDetail(sessionID: sessionID) },
                    onStartSession: { [weak self] in self?.coordinator.startSession() }),
                contentSize: Self.contentSize)
            window = newWindow
        }
        reload()
        if let window, !window.isVisible {
            AppWindowRouter.shared.placeOpenedWindow(window, desiredContentSize: Self.contentSize)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let store = coordinator.sessionStore
        let timeZone = timeZone
        Task {
            let metadataList = (try? await store.listSessions()) ?? []
            var entries: [SessionListEntry] = []
            for metadata in metadataList {
                // A session whose log cannot be read is left out rather than breaking the list.
                if let session = try? await store.loadSession(id: metadata.id) {
                    entries.append(SessionBrowsing.listEntry(for: session, timeZone: timeZone))
                }
            }
            model.items = entries.map { entry in
                SessionListItem(
                    id: entry.id, title: entry.title, startedAt: entry.startedAt, durationSeconds: entry.durationSeconds,
                    questionCount: entry.questionCount, savedProject: entry.savedProject)
            }
        }
    }

    private func openDetail(sessionID: String) {
        if let existing = detailControllers[sessionID] {
            existing.show()
            return
        }
        guard detailOpensInFlight.insert(sessionID).inserted else { return }
        let store = coordinator.sessionStore
        Task {
            defer { detailOpensInFlight.remove(sessionID) }
            guard let session = try? await store.loadSession(id: sessionID) else { return }
            let detailController = SessionDetailWindowController(
                session: session,
                store: store,
                onSaved: { [weak self] in self?.reload() },
                onClosed: { [weak self] closedID in self?.detailControllers[closedID] = nil })
            detailControllers[sessionID] = detailController
            detailController.show()
        }
    }
}
