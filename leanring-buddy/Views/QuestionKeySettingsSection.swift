//
//  QuestionKeySettingsSection.swift
//  leanring-buddy
//
//  The "Question key" section of Settings: the current key, a Record button that
//  listens for the next key press, and a Reset button back to right Command.
//  Recording uses a monitor on this app's own events, so it needs no permission.
//

import AppKit
import Combine
import ClickyCore
import SwiftUI

@MainActor
final class QuestionKeySettingsState: ObservableObject {
    @Published var currentKey: QuestionKeySpec
    @Published var isRecording: Bool
    /// The modifiers held while recording, shown so the user sees the key being built.
    @Published var recordingHint: String
    /// Why the last recording was refused; empty when there is nothing to say.
    @Published var message: String

    var onToggleRecording: () -> Void
    var onReset: () -> Void

    init(
        currentKey: QuestionKeySpec = .default,
        isRecording: Bool = false,
        recordingHint: String = "",
        message: String = "",
        onToggleRecording: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {}
    ) {
        self.currentKey = currentKey
        self.isRecording = isRecording
        self.recordingHint = recordingHint
        self.message = message
        self.onToggleRecording = onToggleRecording
        self.onReset = onReset
    }

    /// What the key field shows.
    var fieldText: String {
        guard isRecording else { return currentKey.displayName }
        return recordingHint.isEmpty ? "Press the new key" : recordingHint + " + ..."
    }

    var isAtDefault: Bool { currentKey == .default }
}

/// Wires `QuestionKeySettingsState` to AppSettings and to the session's key monitor.
@MainActor
final class QuestionKeySettingsController {
    let state: QuestionKeySettingsState
    private var recorder = QuestionKeyRecorder()
    private var eventMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?

    init() {
        state = QuestionKeySettingsState(currentKey: AppSettings.shared.questionKey)
        state.onToggleRecording = { [weak self] in
            guard let self else { return }
            self.state.isRecording ? self.stopRecording() : self.startRecording()
        }
        state.onReset = { [weak self] in
            self?.stopRecording()
            self?.save(.default)
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

    func reloadFromSettings() {
        state.currentKey = AppSettings.shared.questionKey
    }

    private func save(_ spec: QuestionKeySpec) {
        AppSettings.shared.questionKey = spec
        state.currentKey = spec
        state.message = ""
    }

    private func startRecording() {
        recorder = QuestionKeyRecorder()
        state.message = ""
        state.recordingHint = ""
        state.isRecording = true
        // The old key must not start a question while the user is choosing a new one.
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
        if state.isRecording { SessionCoordinator.shared.setQuestionKeyRecording(false) }
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
            stopRecording()
            save(spec)
        case .rejected(let rejection):
            // Stay in recording so the user can press a better key.
            recorder = QuestionKeyRecorder()
            state.message = rejection.message
        }
    }
}

struct QuestionKeySettingsSection: View {
    @ObservedObject var state: QuestionKeySettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Question key")
                    .font(DS.WindowText.windowTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Press it to start a spoken question, and again to send it.\nUse one modifier on its own, or hold several modifiers, with or without one more key.")
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
                    .accessibilityLabel("Question key")
                    .accessibilityValue(state.fieldText)
                    .accessibilityIdentifier("settings.questionKey.field")

                Button(action: state.onToggleRecording) {
                    Text(state.isRecording ? "Cancel" : "Record")
                }
                .clickyWindowButton(.secondary, isCompact: true)
                .accessibilityIdentifier("settings.questionKey.record")
            }

            HStack(spacing: 10) {
                Color.clear.frame(width: 72, height: 1)
                Button(action: state.onReset) {
                    Text("Reset to right Command")
                }
                .clickyWindowButton(.quiet, isCompact: true)
                .disabled(state.isAtDefault && !state.isRecording)
                .accessibilityIdentifier("settings.questionKey.reset")
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
                    .accessibilityIdentifier("settings.questionKey.message")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.questionKey")
    }
}
