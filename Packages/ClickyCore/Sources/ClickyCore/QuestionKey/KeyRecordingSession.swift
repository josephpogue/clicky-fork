import Foundation

/// The message under a Settings key field when a recording was refused. It never outlives its cause: a clash
/// message is checked again when the other key changes, and every other way out clears it.
public struct KeyRefusalMessage: Equatable {
    public private(set) var text = ""
    /// The key that was refused for clashing with the other key; nil for a refusal that has no other key in it.
    private var clashingKey: QuestionKeySpec?

    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    public mutating func showRejection(_ rejection: QuestionKeyRejection) {
        text = rejection.message
        clashingKey = nil
    }

    public mutating func showClash(of key: QuestionKeySpec, text: String) {
        self.text = text
        clashingKey = key
    }

    public mutating func clear() {
        text = ""
        clashingKey = nil
    }

    /// The other key changed: the message goes when the clash is gone, and is reworded when another key clashes now.
    public mutating func otherKeyChanged(refusalNow: (QuestionKeySpec) -> String?) {
        guard let clashingKey else { return }
        if let newText = refusalNow(clashingKey) { text = newText } else { clear() }
    }
}

/// The two keys as saved, which each section checks a new key against.
public struct SavedKeys: Equatable {
    public var question: QuestionKeySpec
    public var chat: QuestionKeySpec

    public init(question: QuestionKeySpec, chat: QuestionKeySpec) {
        self.question = question
        self.chat = chat
    }
}

/// One Settings section's recording: the recorder, the hint, and the refusal message with every rule for when it
/// goes. The view only shows what this holds.
public struct KeyRecordingSession {
    public enum Kind: Equatable { case question, chat }

    public enum Step: Equatable {
        case keepRecording
        case cancelled
        /// The recording is done and the key is fine: save it.
        case save(QuestionKeySpec)
    }

    public let kind: Kind
    public private(set) var isRecording = false
    /// The modifiers held while recording, for the live hint.
    public private(set) var hint = ""
    public private(set) var refusal = KeyRefusalMessage()
    private var recorder: QuestionKeyRecorder

    public init(kind: Kind) {
        self.kind = kind
        recorder = QuestionKeyRecorder(sided: kind == .chat)
    }

    /// Record: a fresh recording, with no held modifiers remembered and no old refusal.
    public mutating func start() {
        recorder = QuestionKeyRecorder(sided: kind == .chat)
        hint = ""
        refusal.clear()
        isRecording = true
    }

    /// Cancel, Escape, the other section taking over, or Settings closing.
    public mutating func cancel() {
        recorder = QuestionKeyRecorder(sided: kind == .chat)
        hint = ""
        refusal.clear()
        isRecording = false
    }

    /// Feeds one key event of the recording.
    public mutating func handle(_ input: QuestionKeyInput, saved: SavedKeys) -> Step {
        guard isRecording else { return .keepRecording }
        let outcome = recorder.handle(input)
        hint = recorder.heldHint
        switch outcome {
        case nil:
            return .keepRecording
        case .cancelled:
            cancel()
            return .cancelled
        case .recorded(let spec):
            if let text = refusalText(for: spec, saved: saved) {
                // Stay in recording so the user can press a different key.
                restartRecorder()
                refusal.showClash(of: spec, text: text)
                return .keepRecording
            }
            cancel()
            return .save(spec)
        case .rejected(let rejection):
            restartRecorder()
            refusal.showRejection(rejection)
            return .keepRecording
        }
    }

    /// Reset: stops any recording and returns the key to save, or nil when the other key refuses it (the message
    /// then says so).
    public mutating func reset(to defaultKey: QuestionKeySpec, saved: SavedKeys) -> QuestionKeySpec? {
        cancel()
        if let text = refusalText(for: defaultKey, saved: saved) {
            refusal.showClash(of: defaultKey, text: text)
            return nil
        }
        return defaultKey
    }

    /// The saved keys changed (either one): a clash message that no longer holds goes, one that changed is reworded.
    public mutating func savedKeysChanged(_ saved: SavedKeys) {
        let kind = kind
        refusal.otherKeyChanged { Self.refusalText(kind: kind, for: $0, saved: saved) }
    }

    /// Settings closed or opens again: nothing from before stays on screen.
    public mutating func settingsClosed() {
        cancel()
    }

    private mutating func restartRecorder() {
        recorder = QuestionKeyRecorder(sided: kind == .chat)
        hint = ""
    }

    private func refusalText(for spec: QuestionKeySpec, saved: SavedKeys) -> String? {
        Self.refusalText(kind: kind, for: spec, saved: saved)
    }

    private static func refusalText(kind: Kind, for spec: QuestionKeySpec, saved: SavedKeys) -> String? {
        switch kind {
        case .question:
            return KeyOverlap.refusalForNewQuestionKey(spec, currentQuestion: saved.question, chat: saved.chat)
        case .chat:
            return KeyOverlap.refusalForChatKey(spec, question: saved.question)
        }
    }
}
