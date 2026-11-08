import Foundation

public enum QuestionKeyRejection: Equatable {
    /// A regular key on its own would fire while the user types.
    case needsModifier
    /// Both sides of one modifier and nothing else cannot be told from either side alone.
    case ambiguousModifiers

    public var message: String {
        switch self {
        case .needsModifier: return "Add a modifier key (Control, Option, Shift or Command), or the key would fire while you type."
        case .ambiguousModifiers: return "Press one modifier key, or two different ones together."
        }
    }
}

public enum QuestionKeyRecordingOutcome: Equatable {
    case cancelled
    case recorded(QuestionKeySpec)
    case rejected(QuestionKeyRejection)
}

/// Turns what the user presses while the Settings field is recording into a new question key.
/// One modifier on its own is a lone-modifier key; two or more modifiers let go together are a modifiers-only
/// combination; modifiers plus one regular key are a combination with a key. Escape on its own cancels.
public struct QuestionKeyRecorder {
    public static let escapeKeyCode: UInt16 = 53

    /// Every modifier key that was down at some point since all were last up.
    private var peakHeld: HeldModifiers = []
    private var currentHeld: HeldModifiers = []

    /// The chat key records sided: every held modifier keeps its side, and the result is a sided combination.
    private let sided: Bool

    public init(sided: Bool = false) { self.sided = sided }

    /// The modifiers down right now, for a live "Control + Option" hint while recording.
    public var heldHint: String {
        if sided { return currentHeld.keys.sorted { $0.keyCode < $1.keyCode }.map(\.displayName).joined(separator: " + ") }
        return currentHeld.families.sorted().map(\.displayName).joined(separator: " + ")
    }

    /// Nil while the user is still pressing; an outcome once the recording is decided.
    public mutating func handle(_ input: QuestionKeyInput) -> QuestionKeyRecordingOutcome? {
        switch input {
        case let .keyDown(keyCode, held, isRepeat, _):
            guard !isRepeat else { return nil }
            let families = held.withoutFunction.families
            if keyCode == Self.escapeKeyCode && families.isEmpty { return .cancelled }
            if sided {
                guard let spec = QuestionKeySpec.makeSidedCombination(modifiers: held.withoutFunction.keys, keyCode: keyCode) else {
                    return .rejected(.needsModifier)
                }
                return .recorded(spec)
            }
            guard let spec = QuestionKeySpec.makeCombination(modifiers: families, keyCode: keyCode) else {
                return .rejected(.needsModifier)
            }
            return .recorded(spec)
        case let .modifiersChanged(held, _):
            currentHeld = held.withoutFunction
            peakHeld.formUnion(currentHeld)
            guard currentHeld.isEmpty, !peakHeld.isEmpty else { return nil }
            defer { peakHeld = [] }
            return outcome(forPeak: peakHeld)
        case .keyUp, .mouseButtonDown:
            return nil
        }
    }

    private func outcome(forPeak peak: HeldModifiers) -> QuestionKeyRecordingOutcome {
        let keys = peak.keys
        if sided, let spec = QuestionKeySpec.makeSidedCombination(modifiers: keys, keyCode: nil) { return .recorded(spec) }
        if keys.count == 1, let key = keys.first { return .recorded(.loneModifier(key)) }
        guard let spec = QuestionKeySpec.makeCombination(modifiers: peak.families, keyCode: nil) else {
            return .rejected(.ambiguousModifiers)
        }
        return .recorded(spec)
    }
}
