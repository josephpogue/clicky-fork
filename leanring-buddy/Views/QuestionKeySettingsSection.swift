//
//  QuestionKeySettingsSection.swift
//  leanring-buddy
//
//  The "Question key" and "Chat key" sections of Settings (one view, used twice): the
//  current key, a Record button that listens for the next key press, and a Reset
//  button back to the default. Recording uses a monitor on this app's own events,
//  so it needs no permission. Each section refuses a key that a single press could
//  share with the other one.
//

import AppKit
import Combine
import ClickyCore
import SwiftUI

/// Which of the two keys a Settings section edits.
enum SettingsKeyKind {
    case question, chat

    var title: String { self == .question ? "Question key" : "Chat key" }
    var blurb: String {
        switch self {
        case .question:
            return "Press it to start a spoken question, and again to send it.\nUse one modifier on its own, or hold several modifiers, with or without one more key."
        case .chat:
            return "Press it during a session to open the chat window, and again to close it.\nHold the modifiers you want with one more key. Left and right modifiers count separately."
        }
    }
    var defaultKey: QuestionKeySpec { self == .question ? .default : .defaultChatKey }
    var resetTitle: String { self == .question ? "Reset to right Command" : "Reset to right \u{2318} ," }
    var identifierPrefix: String { self == .question ? "settings.questionKey" : "settings.chatKey" }
    /// The name this section goes by in `KeyRecordingTracker`.
    var recordingOwnerName: String { self == .question ? "question" : "chat" }
}

@MainActor
final class QuestionKeySettingsState: ObservableObject {
    let kind: SettingsKeyKind
    @Published var currentKey: QuestionKeySpec
    @Published var isRecording: Bool
    /// The modifiers held while recording, shown so the user sees the key being built.
    @Published var recordingHint: String
    /// Why the last recording was refused; empty when there is nothing to say.
    @Published var message: String
    /// Why the key shown does not work right now; stays until the cause is gone. Empty when it works.
    @Published var inactiveNotice: String

    var onToggleRecording: () -> Void
    var onReset: () -> Void

    init(
        kind: SettingsKeyKind = .question,
        currentKey: QuestionKeySpec? = nil,
        isRecording: Bool = false,
        recordingHint: String = "",
        message: String = "",
        inactiveNotice: String = "",
        onToggleRecording: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {}
    ) {
        self.kind = kind
        self.currentKey = currentKey ?? kind.defaultKey
        self.isRecording = isRecording
        self.recordingHint = recordingHint
        self.message = message
        self.inactiveNotice = inactiveNotice
        self.onToggleRecording = onToggleRecording
        self.onReset = onReset
    }

    /// What the key field shows.
    var fieldText: String {
        guard isRecording else { return currentKey.displayName }
        return recordingHint.isEmpty ? "Press the new key" : recordingHint + " + ..."
    }

    var isAtDefault: Bool { currentKey == kind.defaultKey }
}

/// Wires `QuestionKeySettingsState` to AppSettings and to the session's key monitor.
@MainActor
final class QuestionKeySettingsController {
    let state: QuestionKeySettingsState
    private let kind: SettingsKeyKind
    private var recorder: QuestionKeyRecorder
    private var eventMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var keySubscription: AnyCancellable?

    /// The one owner of "a key is being recorded". Both sections' Record buttons work at once (the recording
    /// monitor blocks keys, not clicks), so starting one cancels the other, and the session's keys stay
    /// suspended until no section records.
    private static var recordingTracker = KeyRecordingTracker()
    private static weak var questionSectionController: QuestionKeySettingsController?
    private static weak var chatSectionController: QuestionKeySettingsController?

    init(kind: SettingsKeyKind = .question) {
        self.kind = kind
        recorder = QuestionKeyRecorder(sided: kind == .chat)
        state = QuestionKeySettingsState(kind: kind, currentKey: Self.savedKey(for: kind))
        state.onToggleRecording = { [weak self] in
            guard let self else { return }
            self.state.isRecording ? self.stopRecording() : self.startRecording()
        }
        state.onReset = { [weak self] in
            guard let self else { return }
            self.stopRecording()
            self.saveUnlessOverlapping(kind.defaultKey)
        }
        if kind == .chat {
            Self.chatSectionController = self
            // The chat key yields to the question key, whichever of them changed or was loaded last.
            keySubscription = Publishers.CombineLatest(AppSettings.shared.$questionKey, AppSettings.shared.$chatKey)
                .sink { [weak self] questionKey, chatKey in
                    self?.state.inactiveNotice = KeyOverlap.inactiveChatKeyNotice(chat: chatKey, question: questionKey) ?? ""
                }
        } else {
            Self.questionSectionController = self
        }
        // A recording left open when the window closes would keep swallowing keys.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "settings.nswindow" else { return }
            Task { @MainActor in self?.stopRecording() }
        }
    }

    deinit {
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    private static func savedKey(for kind: SettingsKeyKind) -> QuestionKeySpec {
        kind == .question ? AppSettings.shared.questionKey : AppSettings.shared.chatKey
    }

    func reloadFromSettings() {
        state.currentKey = Self.savedKey(for: kind)
    }

    /// Why the other key refuses `spec`, or nil when a press of `spec` could never fire both.
    private func overlapRefusal(for spec: QuestionKeySpec) -> String? {
        switch kind {
        case .question: return KeyOverlap.refusalForQuestionKey(spec, chat: AppSettings.shared.chatKey)
        case .chat: return KeyOverlap.refusalForChatKey(spec, question: AppSettings.shared.questionKey)
        }
    }

    private func saveUnlessOverlapping(_ spec: QuestionKeySpec) {
        if let refusal = overlapRefusal(for: spec) {
            state.message = refusal
        } else {
            save(spec)
        }
    }

    private func save(_ spec: QuestionKeySpec) {
        switch kind {
        case .question: AppSettings.shared.questionKey = spec
        case .chat: AppSettings.shared.chatKey = spec
        }
        state.currentKey = spec
        state.message = ""
    }

    private func startRecording() {
        recorder = QuestionKeyRecorder(sided: kind == .chat)
        state.message = ""
        state.recordingHint = ""
        state.isRecording = true
        // Only one section records: the other one stops, and the keys stay suspended through the hand-over.
        if let previousOwner = Self.recordingTracker.begin(kind.recordingOwnerName) {
            let previousController = previousOwner == SettingsKeyKind.question.recordingOwnerName
                ? Self.questionSectionController : Self.chatSectionController
            previousController?.stopRecording()
        }
        // Neither key may fire while the user is choosing a new one.
        SessionCoordinator.shared.setQuestionKeyRecording(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Returning nil keeps the press away from the window, so Command+Q or Space do nothing while recording.
            guard let self else { return event }
            MainActor.assumeIsolated { self.handle(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if state.isRecording {
            // A refusal from this recording goes with it (Cancel, Escape, or the other section taking over).
            state.message = ""
            Self.recordingTracker.end(kind.recordingOwnerName)
            // Still suspended when the other section took over recording.
            SessionCoordinator.shared.setQuestionKeyRecording(Self.recordingTracker.isRecording)
        }
        state.isRecording = false
        state.recordingHint = ""
    }

    private func handle(_ event: NSEvent) {
        let held = HeldModifiers(eventFlagBits: UInt64(event.modifierFlags.rawValue))
        let input: QuestionKeyInput
        switch event.type {
        case .keyDown:
            input = .keyDown(keyCode: event.keyCode, held: held, isRepeat: event.isARepeat, time: Date())
        case .flagsChanged:
            input = .modifiersChanged(held: held, time: Date())
        default:
            return
        }
        let outcome = recorder.handle(input)
        state.recordingHint = recorder.heldHint
        switch outcome {
        case nil:
            return
        case .cancelled:
            stopRecording()
        case .recorded(let spec):
            if let refusal = overlapRefusal(for: spec) {
                // Stay in recording so the user can press a different key.
                recorder = QuestionKeyRecorder(sided: kind == .chat)
                state.message = refusal
            } else {
                stopRecording()
                save(spec)
            }
        case .rejected(let rejection):
            // Stay in recording so the user can press a better key.
            recorder = QuestionKeyRecorder(sided: kind == .chat)
            state.message = rejection.message
        }
    }
}

struct QuestionKeySettingsSection: View {
    @ObservedObject var state: QuestionKeySettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.kind.title)
                    .font(DS.WindowText.windowTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(state.kind.blurb)
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Key")
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 72, alignment: .leading)

                Text(state.fieldText)
                    .font(DS.WindowText.body)
                    .foregroundColor(state.isRecording ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 190, minHeight: 28, alignment: .leading)
                    .background(DS.Colors.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(state.isRecording ? DS.Colors.accentText : DS.Colors.borderSubtle, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(state.kind.title)
                    .accessibilityValue(state.fieldText)
                    .accessibilityIdentifier(state.kind.identifierPrefix + ".field")

                Button(action: state.onToggleRecording) {
                    Text(state.isRecording ? "Cancel" : "Record")
                }
                .clickyWindowButton(.secondary, isCompact: true)
                .accessibilityIdentifier(state.kind.identifierPrefix + ".record")
            }

            HStack(spacing: 10) {
                Color.clear.frame(width: 72, height: 1)
                Button(action: state.onReset) {
                    Text(state.kind.resetTitle)
                }
                .clickyWindowButton(.quiet, isCompact: true)
                .disabled(state.isAtDefault && !state.isRecording)
                .accessibilityIdentifier(state.kind.identifierPrefix + ".reset")
            }

            if !state.inactiveNotice.isEmpty {
                Text(state.inactiveNotice)
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(state.kind.identifierPrefix + ".inactive")
            }
            if state.isRecording && state.message.isEmpty {
                Text("Press Escape to cancel.")
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.textMuted)
            }
            if !state.message.isEmpty {
                Text(state.message)
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(state.kind.identifierPrefix + ".message")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(state.kind.identifierPrefix)
    }
}
