//
//  SessionDetailWindowController.swift
//  leanring-buddy
//
//  One session's detail window, and the Save to vault sheet on it. Save is the
//  only place session data leaves the app's data folder, and only when the
//  user confirms the sheet.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

/// What the detail view reads; the controller replaces `state` after a save.
@MainActor
final class SessionDetailModel: ObservableObject {
    @Published var state: SessionDetailState

    init(state: SessionDetailState) {
        self.state = state
    }
}

private struct SessionDetailHost: View {
    @ObservedObject var model: SessionDetailModel
    let onSave: () -> Void
    let onRevealInFinder: () -> Void

    var body: some View {
        SessionDetailView(state: model.state, onSave: onSave, onRevealInFinder: onRevealInFinder)
    }
}

@MainActor
final class SessionDetailWindowController: NSObject, NSWindowDelegate {
    private static let contentSize = CGSize(width: 620, height: 640)

    private let sessionID: String
    private let store: SessionStore
    private let settings = AppSettings.shared
    private let timeZone = TimeZone.current
    private let onSaved: () -> Void
    private let onClosed: (String) -> Void

    private var loadedSession: LoadedSession
    private let model: SessionDetailModel
    private var window: NSWindow?
    private var saveSheet: NSWindow?
    private var saveState: SaveToVaultState?
    private var finishedSubscription: AnyCancellable?

    init(session: LoadedSession, store: SessionStore, onSaved: @escaping () -> Void, onClosed: @escaping (String) -> Void) {
        sessionID = session.metadata.id
        self.store = store
        loadedSession = session
        self.onSaved = onSaved
        self.onClosed = onClosed
        model = SessionDetailModel(state: Self.detailState(for: session, store: store, timeZone: timeZone, settings: AppSettings.shared))
        super.init()
        // The window may have been opened while the session was still running. When the session finishes,
        // show its finished log and summary, and let Save work.
        finishedSubscription = SessionCoordinator.shared.sessionFinished
            .receive(on: DispatchQueue.main)
            .sink { [weak self] finishedSessionID in
                guard let self, finishedSessionID == self.sessionID else { return }
                Task { await self.reloadFromStore() }
            }
    }

    func show() {
        if window == nil {
            let newWindow = WindowHosting.makeStandardWindow(
                title: model.state.title, contentSize: Self.contentSize, isResizable: true, identifier: "detail.nswindow")
            newWindow.contentMinSize = CGSize(width: 480, height: 360)
            newWindow.delegate = self
            newWindow.contentView = WindowHosting.makeHostingView(
                rootView: SessionDetailHost(
                    model: model,
                    onSave: { [weak self] in self?.presentSaveSheet() },
                    onRevealInFinder: { [weak self] in self?.revealInFinder() }),
                contentSize: Self.contentSize)
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Replaces what the window holds with the session as the store has it now. Returns the fresh session,
    /// or nil when it cannot be read (the window then keeps what it has).
    @discardableResult
    private func reloadFromStore() async -> LoadedSession? {
        guard let freshSession = try? await store.loadSession(id: sessionID) else { return nil }
        loadedSession = freshSession
        let freshState = Self.detailState(for: freshSession, store: store, timeZone: timeZone, settings: settings)
        model.state = freshState
        window?.title = freshState.title
        return freshSession
    }

    func windowWillClose(_ notification: Notification) {
        onClosed(sessionID)
    }

    // MARK: - Detail state

    private static func detailState(
        for session: LoadedSession, store: SessionStore, timeZone: TimeZone, settings: AppSettings
    ) -> SessionDetailState {
        let entry = SessionBrowsing.listEntry(for: session, timeZone: timeZone)
        let timeline = SessionBrowsing.timeline(for: session, shotsDirectory: store.shotsDirectory(sessionID: session.metadata.id))
        return SessionDetailState(
            title: entry.title,
            startedAt: session.metadata.startedAt,
            summary: session.metadata.summary,
            rows: timeline.map { row in
                SessionTimelineRow(
                    time: row.time, kind: rowKind(for: row.kind), text: row.text, detail: row.detail, shotFileURL: row.shotFileURL)
            },
            savedNotePath: savedNotePath(for: session.metadata, settings: settings),
            isFinished: session.metadata.endedAt != nil
        )
    }

    private static func rowKind(for kind: SessionTimelineKind) -> SessionTimelineRowKind {
        switch kind {
        case .focus: return .focus
        case .speech: return .speech
        case .question: return .question
        case .answer: return .answer
        case .notice: return .notice
        }
    }

    /// The saved note's full path when the notes folder is known, else the path as it was stored.
    private static func savedNotePath(for metadata: SessionMetadata, settings: AppSettings) -> String? {
        guard let relativePath = metadata.savedVaultNotePath else { return nil }
        let vaultRoot = VaultRootResolver.resolve(
            notesFolderSetting: settings.notesFolderPath, environment: ProcessInfo.processInfo.environment)
        return vaultRoot?.appendingPathComponent(relativePath).path ?? relativePath
    }

    private func revealInFinder() {
        let sessionFolder = store.shotsDirectory(sessionID: sessionID).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([sessionFolder])
    }

    // MARK: - Save sheet

    private func presentSaveSheet() {
        guard window != nil, saveSheet == nil else { return }
        Task {
            // Read the session again first: this window may hold an older copy than the store.
            await reloadFromStore()
            guard model.state.isFinished else { return }
            showSaveSheet()
        }
    }

    private func showSaveSheet() {
        guard let window, saveSheet == nil else { return }
        let state = makeSaveState()
        saveState = state

        let sheetView = SaveToVaultSheet(
            state: state,
            onConfirm: { [weak self] project in self?.confirmSave(project: project) },
            onCancel: { [weak self] in self?.closeSaveSheet() },
            onOpenSettings: { [weak self] in
                self?.closeSaveSheet()
                AppWindowRouter.shared.showSettings()
            })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: sheetView.environment(\.colorScheme, .dark)))
        sheet.appearance = NSAppearance(named: .darkAqua)
        saveSheet = sheet
        window.beginSheet(sheet)
    }

    private func closeSaveSheet() {
        if let saveSheet, let window {
            window.endSheet(saveSheet)
        }
        saveSheet = nil
        saveState = nil
    }

    private func makeSaveState() -> SaveToVaultState {
        guard let vaultRoot = currentVaultRoot() else {
            return SaveToVaultState(projects: [], notesFolderMissing: true)
        }
        let projects = VaultProjects.list(vaultRoot: vaultRoot)
        let entry = SessionBrowsing.listEntry(for: loadedSession, timeZone: timeZone)
        let questions = loadedSession.events.compactMap { event -> String? in
            if case .question(let text, _, _) = event.kind { return text }
            return nil
        }
        let appNames = loadedSession.events.compactMap { event -> String? in
            if case .focusChanged(let appName, _) = event.kind { return appName }
            return nil
        }
        let suggestion = VaultProjects.suggest(
            vaultRoot: vaultRoot, title: entry.title, summary: loadedSession.metadata.summary,
            questions: questions, appNames: appNames)
        return SaveToVaultState(projects: projects, suggestedProject: suggestion)
    }

    private func currentVaultRoot() -> URL? {
        VaultRootResolver.resolve(
            notesFolderSetting: settings.notesFolderPath, environment: ProcessInfo.processInfo.environment)
    }

    private func confirmSave(project: String?) {
        guard let saveState, let vaultRoot = currentVaultRoot() else { return }
        saveState.phase = .saving
        let shotsDirectory = store.shotsDirectory(sessionID: sessionID)
        let isDryRun = VaultRootResolver.isDryRun(environment: ProcessInfo.processInfo.environment)
        let timeZone = timeZone
        Task {
            // Filed from the session as the store has it at this moment, not as it was when the window opened.
            let session = await reloadFromStore() ?? loadedSession
            // The copy and the git commit can take a moment, so they run off the main thread.
            let result = await Task.detached {
                Self.writeToVault(
                    session: session, shotsDirectory: shotsDirectory, vaultRoot: vaultRoot, project: project,
                    isDryRun: isDryRun, timeZone: timeZone)
            }.value
            finishSave(result: result, project: project, vaultRoot: vaultRoot, isDryRun: isDryRun)
        }
    }

    /// Runs the vault save. Pure of UI, so it is safe off the main thread.
    private nonisolated static func writeToVault(
        session: LoadedSession, shotsDirectory: URL, vaultRoot: URL, project: String?, isDryRun: Bool, timeZone: TimeZone
    ) -> Result<VaultSaveResult, VaultSaveFailure> {
        let firstQuestion = session.events.compactMap { event -> String? in
            if case .question(let text, _, _) = event.kind { return text }
            return nil
        }.first
        let noteTitle = SessionNoteTitle.make(
            summary: session.metadata.summary, firstQuestion: firstQuestion, startedAt: session.metadata.startedAt,
            timeZone: timeZone)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        // A shot file that cleanup removed cannot be copied, so it is left out of the copy and of the links.
        let questionShotFileNames = SessionBrowsing.questionShotFileNames(for: session).filter {
            FileManager.default.fileExists(atPath: shotsDirectory.appendingPathComponent($0).path)
        }
        let input = VaultSaveInput(
            vaultRoot: vaultRoot,
            date: dayFormatter.string(from: session.metadata.startedAt),
            title: noteTitle.title,
            slug: noteTitle.slug,
            project: project,
            questionShotFiles: questionShotFileNames.map { shotsDirectory.appendingPathComponent($0) },
            isDryRun: isDryRun)
        return VaultSessionSaver.save(input) { stem in
            SessionLogRenderer.render(
                metadata: session.metadata, events: session.events, shotGroups: session.shotGroups, timeZone: timeZone,
                shotLink: SessionBrowsing.vaultShotLink(
                    stem: stem, questionShotFileNames: Set(questionShotFileNames), shotsDirectory: shotsDirectory))
        }
    }

    private func finishSave(result: Result<VaultSaveResult, VaultSaveFailure>, project: String?, vaultRoot: URL, isDryRun: Bool) {
        guard let saveState else { return }
        switch result {
        case .failure(let failure):
            saveState.phase = .failed(message: Self.plainMessage(for: failure))
        case .success(let saveResult):
            if !isDryRun {
                recordSave(notePath: saveResult.notePath, project: project, vaultRoot: vaultRoot)
            }
            saveState.phase = .saved(
                notePath: saveResult.notePath.path, committed: saveResult.committed, commitError: saveResult.commitError)
        }
    }

    /// Writes where the session went into its own metadata and shows the saved strip. The store loads the
    /// metadata fresh and changes only the two save fields, so a finished session keeps its end time,
    /// summary and cleanup flag.
    private func recordSave(notePath: URL, project: String?, vaultRoot: URL) {
        let rootPrefix = vaultRoot.standardizedFileURL.path + "/"
        let notePathText = notePath.standardizedFileURL.path
        let relativeNotePath = notePathText.hasPrefix(rootPrefix) ? String(notePathText.dropFirst(rootPrefix.count)) : notePathText
        model.state.savedNotePath = notePath.path
        let store = store
        let sessionID = sessionID
        Task {
            if let savedMetadata = try? await store.recordSave(
                sessionID: sessionID, savedVaultNotePath: relativeNotePath, savedProject: project) {
                loadedSession.metadata = savedMetadata
            }
            onSaved()
        }
    }

    private static func plainMessage(for failure: VaultSaveFailure) -> String {
        switch failure {
        case .unknownProject(let project):
            return "The project \(project) is no longer in your notes folder. Choose another project."
        case .writeFailed(let detail):
            return "Could not save to your notes folder. \(detail)"
        }
    }
}
