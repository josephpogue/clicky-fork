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
    private var window: NSWindow?

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
            notesFolderPath: AppSettings.shared.notesFolderPath,
            isSummaryAtStopEnabled: AppSettings.shared.summaryAtStopEnabled
        )
        connectClosures()
    }

    /// Opens the window (activating the app, since Settings is a normal window)
    /// and refreshes sign-in status and answer times.
    func show() {
        if window == nil {
            let newWindow = WindowHosting.makeStandardWindow(
                title: "Clicky Fork Settings", contentSize: Self.contentSize, isResizable: true, identifier: "settings.nswindow")
            newWindow.contentMinSize = CGSize(width: 480, height: 420)
            newWindow.contentView = WindowHosting.makeHostingView(rootView: SettingsView(state: state), contentSize: Self.contentSize)
            window = newWindow
        }
        reloadFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task { await refreshAccounts(clearMessages: true) }
    }

    // MARK: - Closures the view calls

    private func connectClosures() {
        state.onSignIn = { [weak self] providerName in self?.signIn(providerName: providerName) }
        state.onSignOut = { [weak self] providerName in self?.signOut(providerName: providerName) }
        state.onSelectModel = { [weak self] providerName, model in self?.selectModel(model, providerName: providerName) }
        state.onSelectProvider = { [weak self] providerName in self?.selectProvider(providerName: providerName) }
        state.onChooseNotesFolder = { [weak self] in self?.chooseNotesFolder() }
        state.onToggleSummary = { [weak self] isEnabled in
            self?.settings.summaryAtStopEnabled = isEnabled
            self?.state.isSummaryAtStopEnabled = isEnabled
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
            await refreshAccounts(clearMessages: false)
            finishBusyWork(for: providerID, message: failureMessage)
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
            self?.state.notesFolderPath = folderURL.path
        }
        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            openPanel.begin(completionHandler: handleResult)
        }
    }

    // MARK: - Loading state

    /// Copies the plain settings into the state each time the window opens.
    private func reloadFromSettings() {
        state.selectedProviderName = settings.selectedProvider.windowDisplayName
        state.notesFolderPath = settings.notesFolderPath
        state.isSummaryAtStopEnabled = settings.summaryAtStopEnabled
        for providerID in ProviderID.allCases {
            guard let rowIndex = rowIndex(for: providerID) else { continue }
            state.providers[rowIndex].measuredAnswerSeconds = settings.measuredAnswerSeconds[providerID.rawValue]
            state.providers[rowIndex].selectedModel = savedModel(for: providerID)
        }
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
