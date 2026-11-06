//
//  ViewState.swift
//  leanring-buddy
//
//  The state the v1 window views take. The views only read this state and
//  call its closures; the wiring slice owns loading data, opening windows and
//  doing the work behind each closure. Closures must update the state they
//  belong to (for example `onSelectModel` sets `selectedModel`), because the
//  views never change it themselves, except the save sheet's project choice.
//

import Combine
import Foundation

// MARK: - Chat window

enum ChatMessageRole: Equatable {
    case question
    case answer
    /// A line from the app itself, such as "Switched to ChatGPT".
    case notice
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: ChatMessageRole
    var text: String
    var time: Date
    /// "Claude" or "ChatGPT", on answers.
    var providerName: String?
    var model: String?
    var secondsToAnswer: Double?
    /// What the pointer moved to, when the answer carried a point tag.
    var pointLabel: String?

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        time: Date = Date(),
        providerName: String? = nil,
        model: String? = nil,
        secondsToAnswer: Double? = nil,
        pointLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
        self.providerName = providerName
        self.model = model
        self.secondsToAnswer = secondsToAnswer
        self.pointLabel = pointLabel
    }
}

enum QuestionPhase: Equatable {
    case idle
    /// `audioLevel` runs 0...1 and drives the marker's level bars.
    case listening(audioLevel: Double)
    case transcribing
    case waitingForAnswer(providerName: String)
}

struct UsageLimitOffer: Equatable {
    var message: String
    var switchToProviderName: String
}

@MainActor
final class ChatWindowState: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var isSessionRunning: Bool
    @Published var questionPhase: QuestionPhase
    @Published var activeProviderName: String
    @Published var activeModel: String
    @Published var usageLimitOffer: UsageLimitOffer?
    /// Added for the design: the name of the question key as the hint line
    /// says it ("right Command"), so a changed key reads right everywhere.
    @Published var questionKeyLabel: String

    var onSwitchProvider: () -> Void
    var onStopSession: () -> Void
    var onStartSession: () -> Void

    init(
        messages: [ChatMessage] = [],
        isSessionRunning: Bool = false,
        questionPhase: QuestionPhase = .idle,
        activeProviderName: String = "Claude",
        activeModel: String = "sonnet",
        usageLimitOffer: UsageLimitOffer? = nil,
        questionKeyLabel: String = "right Command",
        onSwitchProvider: @escaping () -> Void = {},
        onStopSession: @escaping () -> Void = {},
        onStartSession: @escaping () -> Void = {}
    ) {
        self.messages = messages
        self.isSessionRunning = isSessionRunning
        self.questionPhase = questionPhase
        self.activeProviderName = activeProviderName
        self.activeModel = activeModel
        self.usageLimitOffer = usageLimitOffer
        self.questionKeyLabel = questionKeyLabel
        self.onSwitchProvider = onSwitchProvider
        self.onStopSession = onStopSession
        self.onStartSession = onStartSession
    }
}

// MARK: - Settings

struct ProviderSettingsRow: Identifiable, Equatable {
    var id: String { providerName }
    var providerName: String
    var isSignedIn: Bool
    var accountLabel: String?
    /// True while a sign-in or sign-out is running.
    var isBusy: Bool
    var statusMessage: String?
    var models: [String]
    var selectedModel: String
    var measuredAnswerSeconds: Double?

    init(
        providerName: String,
        isSignedIn: Bool = false,
        accountLabel: String? = nil,
        isBusy: Bool = false,
        statusMessage: String? = nil,
        models: [String] = [],
        selectedModel: String = "",
        measuredAnswerSeconds: Double? = nil
    ) {
        self.providerName = providerName
        self.isSignedIn = isSignedIn
        self.accountLabel = accountLabel
        self.isBusy = isBusy
        self.statusMessage = statusMessage
        self.models = models
        self.selectedModel = selectedModel
        self.measuredAnswerSeconds = measuredAnswerSeconds
    }

    /// "Claude" -> "claude", "ChatGPT" -> "chatgpt": the part of every
    /// accessibility identifier that names this provider.
    var identifierSlug: String {
        providerName.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

@MainActor
final class SettingsState: ObservableObject {
    @Published var providers: [ProviderSettingsRow]
    @Published var selectedProviderName: String
    @Published var notesFolderPath: String?
    @Published var isSummaryAtStopEnabled: Bool

    var onSignIn: (_ providerName: String) -> Void
    var onSignOut: (_ providerName: String) -> Void
    var onSelectModel: (_ providerName: String, _ model: String) -> Void
    var onSelectProvider: (_ providerName: String) -> Void
    var onChooseNotesFolder: () -> Void
    var onToggleSummary: (_ isEnabled: Bool) -> Void

    init(
        providers: [ProviderSettingsRow] = [],
        selectedProviderName: String = "Claude",
        notesFolderPath: String? = nil,
        isSummaryAtStopEnabled: Bool = true,
        onSignIn: @escaping (String) -> Void = { _ in },
        onSignOut: @escaping (String) -> Void = { _ in },
        onSelectModel: @escaping (String, String) -> Void = { _, _ in },
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onChooseNotesFolder: @escaping () -> Void = {},
        onToggleSummary: @escaping (Bool) -> Void = { _ in }
    ) {
        self.providers = providers
        self.selectedProviderName = selectedProviderName
        self.notesFolderPath = notesFolderPath
        self.isSummaryAtStopEnabled = isSummaryAtStopEnabled
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
        self.onSelectModel = onSelectModel
        self.onSelectProvider = onSelectProvider
        self.onChooseNotesFolder = onChooseNotesFolder
        self.onToggleSummary = onToggleSummary
    }
}

// MARK: - Session list and detail

struct SessionListItem: Identifiable, Equatable {
    /// The session's folder name in the app's data folder.
    var id: String
    var title: String
    var startedAt: Date
    var durationSeconds: Double
    var questionCount: Int
    /// The vault project the session was saved under, when it was saved.
    var savedProject: String?
}

enum SessionTimelineRowKind: Equatable {
    /// The user switched app or window.
    case focus
    /// Something the user said outside a question.
    case speech
    case question
    case answer
    case notice
}

struct SessionTimelineRow: Identifiable, Equatable {
    let id: UUID
    var time: Date
    var kind: SessionTimelineRowKind
    var text: String
    /// A short second line, such as "Claude · sonnet · 2.4 s".
    var detail: String?
    var shotFileURL: URL?

    init(
        id: UUID = UUID(),
        time: Date,
        kind: SessionTimelineRowKind,
        text: String,
        detail: String? = nil,
        shotFileURL: URL? = nil
    ) {
        self.id = id
        self.time = time
        self.kind = kind
        self.text = text
        self.detail = detail
        self.shotFileURL = shotFileURL
    }
}

struct SessionDetailState: Equatable {
    var title: String
    var startedAt: Date
    var summary: String?
    var rows: [SessionTimelineRow]
    /// Where Save last wrote the note; nil until the session is saved.
    var savedNotePath: String?

    init(title: String, startedAt: Date, summary: String? = nil, rows: [SessionTimelineRow] = [], savedNotePath: String? = nil) {
        self.title = title
        self.startedAt = startedAt
        self.summary = summary
        self.rows = rows
        self.savedNotePath = savedNotePath
    }
}

// MARK: - Save to vault

enum SaveToVaultPhase: Equatable {
    case choosing
    case saving
    case saved(notePath: String, committed: Bool, commitError: String?)
    case failed(message: String)
}

/// A class rather than a struct because its phase changes while the sheet is
/// open (choosing, saving, saved) and the sheet changes `selectedProject`.
@MainActor
final class SaveToVaultState: ObservableObject {
    @Published var projects: [String]
    @Published var suggestedProject: String?
    /// nil means "No project".
    @Published var selectedProject: String?
    @Published var phase: SaveToVaultPhase
    @Published var notesFolderMissing: Bool

    /// Starts with the suggestion selected, so one press of Save files the
    /// session where the app thinks it belongs.
    init(
        projects: [String],
        suggestedProject: String? = nil,
        phase: SaveToVaultPhase = .choosing,
        notesFolderMissing: Bool = false
    ) {
        self.projects = projects
        self.suggestedProject = suggestedProject
        self.selectedProject = suggestedProject
        self.phase = phase
        self.notesFolderMissing = notesFolderMissing
    }
}
