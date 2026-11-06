//
//  SettingsWindowController.swift
//  leanring-buddy
//
//  Settings: sign in and out of Claude and ChatGPT on the app's own logins,
//  pick models and the answering provider, choose the notes folder and the
//  summary switch. Builds the `SettingsState` the designer's view reads and
//  keeps it in step with `AppSettings` and the two CLI accounts.
//

import AppKit
import ClickyCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private static let contentSize = CGSize(width: 520, height: 760)
    private static let signingInMessage = "Finish signing in in your browser"

    private let settings = AppSettings.shared
    private let accountsByProvider: [ProviderID: any ProviderAccount]
    private let state: SettingsState
    private let answerDeliveryController = AnswerDeliverySettingsController()
    private var window: NSWindow?
    /// Providers whose sign-in the user cancelled, so the ended login shows as cancelled, not as a failure.
    private var providersWithCancelledSignIn: Set<ProviderID> = []

    init() {
        // Both accounts are made with the app's own data folders, which is what
        // keeps these sign-ins apart from any Claude Code or Codex the user has.
        let locations = SessionCoordinator.shared.locations
        accountsByProvider = [
            .claude: ClaudeCLIAccount(locations: locations),
            .chatgpt: CodexCLIAccount(locations: locations),
        ]
        state = SettingsState(
            providers: ProviderID.allCases.map { ProviderSettingsRow(providerName: $0.windowDisplayName) },
            selectedProviderName: AppSettings.shared.selectedProvider.windowDisplayName,
            notesFolderPath: Self.effectiveNotesFolderPath(notesFolderSetting: AppSettings.shared.notesFolderPath),
            isNotesFolderSetByEnvironment: Self.isNotesFolderSetByEnvironment,
            isSummaryAtStopEnabled: AppSettings.shared.summaryAtStopEnabled,
            searchFolderPaths: AppSettings.shared.brainSearchFolderPaths,
            digDeeperEffort: AppSettings.shared.digDeeperEffort
        )
        connectClosures()
        // The index status line updates live while Settings is open.
        BrainIndexService.shared.onStatusChange = { [weak self] status in
            self?.state.searchFolderIndexStatus = Self.indexStatus(from: status)
        }
    }

    /// Opens the window (activating the app, since Settings is a normal window)
    /// and refreshes sign-in status and answer times.
    func show() {
        if window == nil {
            let newWindow = WindowHosting.makeStandardWindow(
                title: "Clicky Fork Settings", contentSize: Self.contentSize, isResizable: true, identifier: "settings.nswindow")
            newWindow.contentMinSize = CGSize(width: 480, height: 420)
            newWindow.contentView = WindowHosting.makeHostingView(rootView: SettingsView(state: state, answerDeliveryState: answerDeliveryController.state), contentSize: Self.contentSize)
            window = newWindow
        }
        reloadFromSettings()
        if let window, !window.isVisible {
            // 760 high runs under the Dock on a 1024x768 display, and the chat panel can cover its right side;
            // the placement shrinks the window to the free screen and moves it clear of the panel. The view scrolls.
            AppWindowRouter.shared.placeOpenedWindow(window, desiredContentSize: Self.contentSize)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task { await refreshAccounts(clearMessages: true) }
    }

    // MARK: - Closures the view calls

    private func connectClosures() {
        state.onSignIn = { [weak self] providerName in self?.signIn(providerName: providerName) }
        state.onCancelSignIn = { [weak self] providerName in self?.cancelSignIn(providerName: providerName) }
        state.onSignOut = { [weak self] providerName in self?.signOut(providerName: providerName) }
        state.onSelectModel = { [weak self] providerName, model in self?.selectModel(model, providerName: providerName) }
        state.onSelectProvider = { [weak self] providerName in self?.selectProvider(providerName: providerName) }
        state.onChooseNotesFolder = { [weak self] in self?.chooseNotesFolder() }
        state.onToggleSummary = { [weak self] isEnabled in
            self?.settings.summaryAtStopEnabled = isEnabled
            self?.state.isSummaryAtStopEnabled = isEnabled
        }
        state.onAddSearchFolder = { [weak self] in self?.addSearchFolder() }
        state.onRemoveSearchFolder = { [weak self] path in self?.removeSearchFolder(path: path) }
        state.onChangeDigDeeperModel = { [weak self] providerName, model in
            self?.changeDigDeeperModel(model, providerName: providerName)
        }
        state.onChangeDigDeeperEffort = { [weak self] effort in
            self?.settings.digDeeperEffort = effort
            self?.state.digDeeperEffort = effort
        }
    }

    private func signIn(providerName: String) {
        guard let providerID = ProviderID(windowDisplayName: providerName),
              let account = accountsByProvider[providerID] else { return }
        guard let rowIndex = rowIndex(for: providerID), !state.providers[rowIndex].isBusy else { return }
        state.providers[rowIndex].isBusy = true
        state.providers[rowIndex].statusMessage = Self.signingInMessage
        Task {
            var failureMessage: String?
            do {
                try await account.signIn()
            } catch {
                failureMessage = Self.plainMessage(for: error, fallback: "Sign-in did not finish.")
            }
            if providersWithCancelledSignIn.remove(providerID) != nil {
                failureMessage = "Sign-in cancelled."
            }
            await refreshAccounts(clearMessages: false)
            finishBusyWork(for: providerID, message: failureMessage)
        }
    }

    /// Ends the login tool that is waiting for the browser. The sign-in task then returns on its own,
    /// which refreshes the row and frees the button.
    private func cancelSignIn(providerName: String) {
        guard let providerID = ProviderID(windowDisplayName: providerName),
              let rowIndex = rowIndex(for: providerID), state.providers[rowIndex].isBusy,
              !state.providers[rowIndex].isSignedIn else { return }
        providersWithCancelledSignIn.insert(providerID)
        Task {
            // The tool starts a moment after the button is pressed, so a very early Cancel tries again briefly.
            for _ in 0..<10 {
                // Off the main thread: ending a process waits for it to exit.
                let endedCount = await Task.detached { Self.endLogin(of: providerID) }.value
                if endedCount > 0 { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard providersWithCancelledSignIn.contains(providerID) else { return }
            }
        }
    }

    @discardableResult
    private nonisolated static func endLogin(of providerID: ProviderID) -> Int {
        switch providerID {
        case .claude:
            return SignInProcessEnder.endLoginProcesses(toolName: "claude", loginArguments: ["auth", "login"])
        case .chatgpt:
            return SignInProcessEnder.endLoginProcesses(toolName: "codex", loginArguments: ["login"])
        }
    }

    private func signOut(providerName: String) {
        guard let providerID = ProviderID(windowDisplayName: providerName),
              let account = accountsByProvider[providerID] else { return }
        guard let rowIndex = rowIndex(for: providerID), !state.providers[rowIndex].isBusy else { return }
        state.providers[rowIndex].isBusy = true
        state.providers[rowIndex].statusMessage = nil
        Task {
            var failureMessage: String?
            do {
                try await account.signOut()
            } catch {
                failureMessage = Self.plainMessage(for: error, fallback: "Sign-out did not finish.")
            }
            await refreshAccounts(clearMessages: false)
            finishBusyWork(for: providerID, message: failureMessage)
        }
    }

    private func finishBusyWork(for providerID: ProviderID, message: String?) {
        guard let rowIndex = rowIndex(for: providerID) else { return }
        state.providers[rowIndex].isBusy = false
        state.providers[rowIndex].statusMessage = message
    }

    private func selectModel(_ model: String, providerName: String) {
        guard let providerID = ProviderID(windowDisplayName: providerName),
              let rowIndex = rowIndex(for: providerID) else { return }
        switch providerID {
        case .claude: settings.claudeModel = model
        case .chatgpt: settings.chatgptModel = model
        }
        state.providers[rowIndex].selectedModel = model
    }

    private func selectProvider(providerName: String) {
        guard let providerID = ProviderID(windowDisplayName: providerName),
              let rowIndex = rowIndex(for: providerID),
              state.providers[rowIndex].isSignedIn else { return }
        settings.selectedProvider = providerID
        state.selectedProviderName = providerName
    }

    private func chooseNotesFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose"
        openPanel.message = "Choose the folder saved sessions are written into."
        if let existingPath = settings.notesFolderPath {
            openPanel.directoryURL = URL(fileURLWithPath: existingPath, isDirectory: true)
        }
        let handleResult: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folderURL = openPanel.url else { return }
            self?.settings.notesFolderPath = folderURL.path
            self?.reloadNotesFolder()
        }
        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            openPanel.begin(completionHandler: handleResult)
        }
    }

    private func addSearchFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Add"
        openPanel.message = "Choose a folder whose notes Clicky may search when a question needs them."
        let handleResult: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folderURL = openPanel.url, let self else { return }
            let chosenPath = folderURL.standardizedFileURL.path
            guard !self.settings.brainSearchFolderPaths.contains(chosenPath) else { return }
            self.settings.brainSearchFolderPaths.append(chosenPath)
            self.state.searchFolderPaths = self.settings.brainSearchFolderPaths
            BrainIndexService.shared.folderListDidChange()
        }
        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            openPanel.begin(completionHandler: handleResult)
        }
    }

    private func removeSearchFolder(path: String) {
        guard settings.brainSearchFolderPaths.contains(path) else { return }
        settings.brainSearchFolderPaths.removeAll { $0 == path }
        state.searchFolderPaths = settings.brainSearchFolderPaths
        BrainIndexService.shared.folderListDidChange()
    }

    private func changeDigDeeperModel(_ model: String, providerName: String) {
        guard let providerID = ProviderID(windowDisplayName: providerName) else { return }
        switch providerID {
        case .claude: settings.digDeeperClaudeModel = model
        case .chatgpt: settings.digDeeperChatgptModel = model
        }
        reloadDigDeeperModelRows()
    }

    /// The dig-deeper lists follow the provider rows' model lists; the selections come from the two saved settings.
    private func reloadDigDeeperModelRows() {
        let claudeRowModels = rowIndex(for: .claude).map { state.providers[$0].models } ?? []
        let chatgptRowModels = rowIndex(for: .chatgpt).map { state.providers[$0].models } ?? []
        state.digDeeperModelRows = [
            DigDeeperModelRow(
                providerName: ProviderID.claude.windowDisplayName,
                models: BrainServiceDigDeeperModels.claude(providerRowModels: claudeRowModels),
                selectedModel: settings.digDeeperClaudeModel),
            DigDeeperModelRow(
                providerName: ProviderID.chatgpt.windowDisplayName,
                models: BrainServiceDigDeeperModels.chatgpt(providerRowModels: chatgptRowModels),
                selectedModel: settings.digDeeperChatgptModel),
        ]
    }

    private static func indexStatus(from status: BrainServiceStatus?) -> SearchFolderIndexStatus? {
        guard let status else { return nil }
        switch status.kind {
        case .ready: return SearchFolderIndexStatus(text: status.text, kind: .ready)
        case .working: return SearchFolderIndexStatus(text: status.text, kind: .working)
        case .problem: return SearchFolderIndexStatus(text: status.text, kind: .problem)
        }
    }

    // MARK: - Loading state

    /// Copies the plain settings into the state each time the window opens.
    private func reloadFromSettings() {
        answerDeliveryController.reloadFromSettings()
        state.selectedProviderName = settings.selectedProvider.windowDisplayName
        reloadNotesFolder()
        state.isSummaryAtStopEnabled = settings.summaryAtStopEnabled
        state.searchFolderPaths = settings.brainSearchFolderPaths
        state.searchFolderIndexStatus = Self.indexStatus(from: BrainIndexService.shared.currentStatus)
        state.digDeeperEffort = settings.digDeeperEffort
        reloadDigDeeperModelRows()
        for providerID in ProviderID.allCases {
            guard let rowIndex = rowIndex(for: providerID) else { continue }
            state.providers[rowIndex].measuredAnswerSeconds = settings.measuredAnswerSeconds[providerID.rawValue]
            state.providers[rowIndex].selectedModel = savedModel(for: providerID)
        }
    }

    /// Shows the folder Save will really use: CLICKY_VAULT_ROOT wins over the folder chosen here.
    private func reloadNotesFolder() {
        state.notesFolderPath = Self.effectiveNotesFolderPath(notesFolderSetting: settings.notesFolderPath)
        state.isNotesFolderSetByEnvironment = Self.isNotesFolderSetByEnvironment
    }

    private static func effectiveNotesFolderPath(notesFolderSetting: String?) -> String? {
        VaultRootResolver.resolve(
            notesFolderSetting: notesFolderSetting, environment: ProcessInfo.processInfo.environment)?.path
    }

    private static var isNotesFolderSetByEnvironment: Bool {
        VaultRootResolver.resolve(notesFolderSetting: nil, environment: ProcessInfo.processInfo.environment) != nil
    }

    /// Asks both CLIs whether they are signed in and which models they accept.
    /// Busy flags and messages stay as they are unless `clearMessages` is true.
    private func refreshAccounts(clearMessages: Bool) async {
        let accounts = accountsByProvider
        for providerID in ProviderID.allCases {
            guard let account = accounts[providerID] else { continue }
            let accountStatus = await account.status()
            // Models are offered only for a signed-in provider.
            let models = accountStatus.isSignedIn ? await account.availableModels() : []
            guard let rowIndex = rowIndex(for: providerID) else { continue }
            state.providers[rowIndex].isSignedIn = accountStatus.isSignedIn
            state.providers[rowIndex].accountLabel = accountStatus.accountLabel
            state.providers[rowIndex].models = models
            if providerID == .chatgpt, accountStatus.isSignedIn, settings.chatgptModel.isEmpty, let firstModel = models.first {
                settings.chatgptModel = firstModel
            }
            state.providers[rowIndex].selectedModel = savedModel(for: providerID)
            state.providers[rowIndex].measuredAnswerSeconds = settings.measuredAnswerSeconds[providerID.rawValue]
            if clearMessages, !state.providers[rowIndex].isBusy {
                state.providers[rowIndex].statusMessage = nil
            }
        }
        reloadDigDeeperModelRows()
    }

    private func savedModel(for providerID: ProviderID) -> String {
        switch providerID {
        case .claude: return settings.claudeModel
        case .chatgpt: return settings.chatgptModel
        }
    }

    private func rowIndex(for providerID: ProviderID) -> Int? {
        state.providers.firstIndex { $0.providerName == providerID.windowDisplayName }
    }

    private static func plainMessage(for error: Error, fallback: String) -> String {
        switch error as? ProviderFailure {
        case .failed(let message): return message
        case .cliNotFound: return "The command line tool for this sign-in was not found."
        case .notSignedIn: return "Not signed in."
        case .notSubscriptionLogin(let detail): return "This login is not a subscription login. \(detail)"
        case .usageLimitReached(let message): return message
        case nil: return fallback
        }
    }
}
