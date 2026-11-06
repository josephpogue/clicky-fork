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

import ClickyCore
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
    /// The notes the answer read from the search folders, in the order read: each a full path (or a path inside
    /// a search folder). The chat shows only the file name, with the whole path on hover. Empty for screen-only answers.
    var notesRead: [String]
    /// True while the answer is still coming: `text` is the text so far and grows with each report. Set it to
    /// false when the answer is done; the chat then shows the timing and the notes read.
    var isStillComing: Bool

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        time: Date = Date(),
        providerName: String? = nil,
        model: String? = nil,
        secondsToAnswer: Double? = nil,
        pointLabel: String? = nil,
        notesRead: [String] = [],
        isStillComing: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
        self.providerName = providerName
        self.model = model
        self.secondsToAnswer = secondsToAnswer
        self.pointLabel = pointLabel
        self.notesRead = notesRead
        self.isStillComing = isStillComing
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
    /// The same phase the menu panel shows: the chat window reads Starting and Stopping from it too.
    @Published var sessionPhase: SessionLifecyclePhase
    /// What Start is waiting for right now, while the phase is Starting.
    @Published var startStepText: String?
    @Published var questionPhase: QuestionPhase
    @Published var activeProviderName: String
    @Published var activeModel: String
    @Published var usageLimitOffer: UsageLimitOffer?
    /// True while a provider switch is running, so both switch buttons wait.
    @Published var isSwitchInProgress: Bool = false
    /// Added for the design: the name of the question key as the hint line
    /// says it ("right Command"), so a changed key reads right everywhere.
    @Published var questionKeyLabel: String
    /// True while the answer being written is searching the user's folders: the latest card shows "Checking
    /// your notes" at the end of the growing answer, or alone before any answer text has come.
    @Published var isCheckingNotes: Bool

    var isSessionRunning: Bool { sessionPhase == .running }

    var onSwitchProvider: () -> Void
    var onStopSession: () -> Void
    var onStartSession: () -> Void

    init(
        messages: [ChatMessage] = [],
        sessionPhase: SessionLifecyclePhase = .idle,
        startStepText: String? = nil,
        questionPhase: QuestionPhase = .idle,
        activeProviderName: String = "Claude",
        activeModel: String = "sonnet",
        usageLimitOffer: UsageLimitOffer? = nil,
        questionKeyLabel: String = "right Command",
        isCheckingNotes: Bool = false,
        onSwitchProvider: @escaping () -> Void = {},
        onStopSession: @escaping () -> Void = {},
        onStartSession: @escaping () -> Void = {}
    ) {
        self.messages = messages
        self.sessionPhase = sessionPhase
        self.startStepText = startStepText
        self.questionPhase = questionPhase
        self.activeProviderName = activeProviderName
        self.activeModel = activeModel
        self.usageLimitOffer = usageLimitOffer
        self.questionKeyLabel = questionKeyLabel
        self.isCheckingNotes = isCheckingNotes
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

/// The quiet line under the search folders that says how the index is doing. The app writes the text
/// ("1,284 notes indexed", "Indexing...", "Could not read ~/x"); the kind picks its look.
struct SearchFolderIndexStatus: Equatable {
    enum Kind: Equatable {
        /// Done and current: plain muted text.
        case ready
        /// Indexing now: a small spinner before the text.
        case working
        /// Something could not be read: amber text with a warning mark.
        case problem
    }

    var text: String
    var kind: Kind

    init(text: String, kind: Kind = .ready) {
        self.text = text
        self.kind = kind
    }
}

/// One provider's model choice for "dig deeper", drawn like the provider card's Model pills.
struct DigDeeperModelRow: Identifiable, Equatable {
    var id: String { providerName }
    /// "Claude" or "ChatGPT", as in `ProviderSettingsRow.providerName`.
    var providerName: String
    /// The models to offer, in order. An empty string is the CLI's own default and shows as "default".
    /// An empty list shows "Sign in to choose" (a provider that is not signed in has no model list).
    var models: [String]
    /// The chosen model; an empty string is the CLI's own default.
    var selectedModel: String

    init(providerName: String, models: [String], selectedModel: String) {
        self.providerName = providerName
        self.models = models
        self.selectedModel = selectedModel
    }

    /// Same slug rule as `ProviderSettingsRow.identifierSlug`.
    var identifierSlug: String {
        providerName.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// What Settings shows before the app fills the real lists: Claude on opus, ChatGPT on the CLI default.
    static let defaultRows: [DigDeeperModelRow] = [
        DigDeeperModelRow(providerName: "Claude", models: ["sonnet", "opus", "haiku"], selectedModel: "opus"),
        DigDeeperModelRow(providerName: "ChatGPT", models: [""], selectedModel: ""),
    ]
}

@MainActor
final class SettingsState: ObservableObject {
    @Published var providers: [ProviderSettingsRow]
    @Published var selectedProviderName: String
    /// The folder Save will really use, which may come from CLICKY_VAULT_ROOT rather than the user's choice.
    @Published var notesFolderPath: String?
    /// True when CLICKY_VAULT_ROOT sets the notes folder, so the window can say why a choice does not apply.
    @Published var isNotesFolderSetByEnvironment: Bool
    @Published var isSummaryAtStopEnabled: Bool
    /// The folders Clicky may search, as full paths (the view shows the home folder as "~"). Empty turns the
    /// search off and the section shows only its caption and Add folder.
    @Published var searchFolderPaths: [String]
    /// The line under the folder list; nil shows none. Not shown while the list is empty.
    @Published var searchFolderIndexStatus: SearchFolderIndexStatus?
    /// The stronger model per provider used when the user says "dig deeper".
    @Published var digDeeperModelRows: [DigDeeperModelRow]
    /// The effort used when the user says "dig deeper". High by default.
    @Published var digDeeperEffort: AnswerEffort

    var onSignIn: (_ providerName: String) -> Void
    var onCancelSignIn: (_ providerName: String) -> Void
    var onSignOut: (_ providerName: String) -> Void
    var onSelectModel: (_ providerName: String, _ model: String) -> Void
    var onSelectProvider: (_ providerName: String) -> Void
    var onChooseNotesFolder: () -> Void
    var onToggleSummary: (_ isEnabled: Bool) -> Void
    /// Add folder was pressed: show the folder picker, then append the chosen path to `searchFolderPaths`.
    var onAddSearchFolder: () -> Void
    /// A folder row's remove control was pressed; `path` is the full path exactly as in `searchFolderPaths`.
    var onRemoveSearchFolder: (_ path: String) -> Void
    /// A dig-deeper model pill was pressed; `model` is "" for the CLI's own default. Update `digDeeperModelRows`.
    var onChangeDigDeeperModel: (_ providerName: String, _ model: String) -> Void
    /// A dig-deeper effort chip was pressed. Update `digDeeperEffort`.
    var onChangeDigDeeperEffort: (_ effort: AnswerEffort) -> Void

    init(
        providers: [ProviderSettingsRow] = [],
        selectedProviderName: String = "Claude",
        notesFolderPath: String? = nil,
        isNotesFolderSetByEnvironment: Bool = false,
        isSummaryAtStopEnabled: Bool = true,
        searchFolderPaths: [String] = [],
        searchFolderIndexStatus: SearchFolderIndexStatus? = nil,
        digDeeperModelRows: [DigDeeperModelRow] = DigDeeperModelRow.defaultRows,
        digDeeperEffort: AnswerEffort = .high,
        onSignIn: @escaping (String) -> Void = { _ in },
        onCancelSignIn: @escaping (String) -> Void = { _ in },
        onSignOut: @escaping (String) -> Void = { _ in },
        onSelectModel: @escaping (String, String) -> Void = { _, _ in },
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onChooseNotesFolder: @escaping () -> Void = {},
        onToggleSummary: @escaping (Bool) -> Void = { _ in },
        onAddSearchFolder: @escaping () -> Void = {},
        onRemoveSearchFolder: @escaping (String) -> Void = { _ in },
        onChangeDigDeeperModel: @escaping (String, String) -> Void = { _, _ in },
        onChangeDigDeeperEffort: @escaping (AnswerEffort) -> Void = { _ in }
    ) {
        self.providers = providers
        self.selectedProviderName = selectedProviderName
        self.notesFolderPath = notesFolderPath
        self.isNotesFolderSetByEnvironment = isNotesFolderSetByEnvironment
        self.isSummaryAtStopEnabled = isSummaryAtStopEnabled
        self.searchFolderPaths = searchFolderPaths
        self.searchFolderIndexStatus = searchFolderIndexStatus
        self.digDeeperModelRows = digDeeperModelRows
        self.digDeeperEffort = digDeeperEffort
        self.onSignIn = onSignIn
        self.onCancelSignIn = onCancelSignIn
        self.onSignOut = onSignOut
        self.onSelectModel = onSelectModel
        self.onSelectProvider = onSelectProvider
        self.onChooseNotesFolder = onChooseNotesFolder
        self.onToggleSummary = onToggleSummary
        self.onAddSearchFolder = onAddSearchFolder
        self.onRemoveSearchFolder = onRemoveSearchFolder
        self.onChangeDigDeeperModel = onChangeDigDeeperModel
        self.onChangeDigDeeperEffort = onChangeDigDeeperEffort
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
    /// False while the session is running or has not finished (no end time yet); Save waits for it.
    var isFinished: Bool

    init(title: String, startedAt: Date, summary: String? = nil, rows: [SessionTimelineRow] = [], savedNotePath: String? = nil, isFinished: Bool = true) {
        self.title = title
        self.startedAt = startedAt
        self.summary = summary
        self.rows = rows
        self.savedNotePath = savedNotePath
        self.isFinished = isFinished
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
