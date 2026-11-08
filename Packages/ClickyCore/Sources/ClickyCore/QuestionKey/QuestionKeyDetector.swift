import Foundation

/// One keyboard or mouse event, reduced to what the question key needs. The app layer stamps `time`.
public enum QuestionKeyInput: Equatable {
    /// A modifier key went down or up; `held` is every modifier down after the change.
    case modifiersChanged(held: HeldModifiers, time: Date)
    case keyDown(keyCode: UInt16, held: HeldModifiers, isRepeat: Bool, time: Date)
    case keyUp(keyCode: UInt16, time: Date)
    case mouseButtonDown(time: Date)
}

public struct QuestionKeyDetection: Equatable {
    /// Set when the question key was just used; feed it to `QuestionKeyStateMachine`.
    public var tap: LoneTap?
    /// True when this event is part of the key combination and must not reach the app the user is in.
    public var swallowEvent: Bool

    public init(tap: LoneTap? = nil, swallowEvent: Bool = false) {
        self.tap = tap
        self.swallowEvent = swallowEvent
    }
}

/// Watches events for the chosen question key and reports each use of it.
public struct QuestionKeyDetector {
    public let spec: QuestionKeySpec
    public let maximumHoldDuration: TimeInterval

    private var loneDetector: LoneModifierTapDetector
    private var previousHeld: HeldModifiers = []

    // Modifiers-only combination: the moment the exact set came down, if the press is still clean.
    private var comboReachedAt: Date?
    private var comboSpoiled = false
    // Combination with a key: the key's release is hidden too, so the app never sees half a key press.
    private var swallowingKeyUp: UInt16?

    public init(spec: QuestionKeySpec = .default, maximumHoldDuration: TimeInterval = 1.0) {
        self.spec = spec
        self.maximumHoldDuration = maximumHoldDuration
        let target: ModifierKey
        if case .loneModifier(let key) = spec { target = key } else { target = .rightCommand }
        loneDetector = LoneModifierTapDetector(targetKeyCode: target.keyCode, maximumHoldDuration: maximumHoldDuration)
    }

    public mutating func handle(_ input: QuestionKeyInput) -> QuestionKeyDetection {
        switch spec {
        case .loneModifier(let key):
            return QuestionKeyDetection(tap: handleLone(input, key: key))
        case .combination(let modifiers, let keyCode):
            if let keyCode { return handleKeyCombination(input, modifiers: modifiers, keyCode: keyCode) }
            return QuestionKeyDetection(tap: handleModifiersOnly(input, modifiers: modifiers))
        }
    }

    // MARK: Lone modifier

    private mutating func handleLone(_ input: QuestionKeyInput, key: ModifierKey) -> LoneTap? {
        switch input {
        case let .modifiersChanged(held, time):
            let changed = held.symmetricDifference(previousHeld)
            previousHeld = held
            return loneDetector.handle(.modifierFlagsChanged(
                keyCode: changed.contains(key.heldBit) ? key.keyCode : 0,
                isTargetKeyDown: held.contains(key.heldBit),
                otherModifiersHeld: !held.subtracting(key.heldBit).isEmpty,
                time: time))
        case let .keyDown(keyCode, _, _, time):
            return loneDetector.handle(.keyDown(keyCode: keyCode, time: time))
        case .keyUp:
            return nil
        case let .mouseButtonDown(time):
            return loneDetector.handle(.mouseButtonDown(time: time))
        }
    }

    // MARK: Modifiers plus a regular key

    private mutating func handleKeyCombination(_ input: QuestionKeyInput, modifiers: Set<ModifierFamily>, keyCode: UInt16) -> QuestionKeyDetection {
        switch input {
        case let .keyDown(code, held, isRepeat, time):
            guard code == keyCode, held.withoutFunction.families == modifiers else {
                return QuestionKeyDetection()
            }
            swallowingKeyUp = keyCode
            // A key held down repeats; only the first press counts, and the repeats stay hidden.
            return QuestionKeyDetection(tap: isRepeat ? nil : LoneTap(pressedAt: time, releasedAt: time), swallowEvent: true)
        case let .keyUp(code, _):
            guard code == keyCode, swallowingKeyUp == keyCode else { return QuestionKeyDetection() }
            swallowingKeyUp = nil
            return QuestionKeyDetection(swallowEvent: true)
        case .modifiersChanged, .mouseButtonDown:
            return QuestionKeyDetection()
        }
    }

    // MARK: Modifiers only

    private mutating func handleModifiersOnly(_ input: QuestionKeyInput, modifiers: Set<ModifierFamily>) -> LoneTap? {
        switch input {
        case let .modifiersChanged(held, time):
            return handleModifiersOnlyChange(held: held, modifiers: modifiers, time: time)
        case let .keyDown(_, held, _, _):
            // Any key typed while modifiers are down means the modifiers belong to a shortcut, not to us.
            if !held.isEmpty { spoilComboPress() }
            return nil
        case .keyUp:
            return nil
        case .mouseButtonDown:
            spoilComboPress()
            return nil
        }
    }

    private mutating func spoilComboPress() {
        comboSpoiled = true
        comboReachedAt = nil
    }

    private mutating func handleModifiersOnlyChange(held: HeldModifiers, modifiers: Set<ModifierFamily>, time: Date) -> LoneTap? {
        defer { previousHeld = held }
        if held.isEmpty {
            // Letting go of everything straight from the exact set is a release, so it can complete the tap.
            let reachedAt = comboReachedAt
            comboSpoiled = false
            comboReachedAt = nil
            guard let reachedAt, time.timeIntervalSince(reachedAt) < maximumHoldDuration else { return nil }
            return LoneTap(pressedAt: reachedAt, releasedAt: time)
        }
        // Fn held means the press is not a clean combination.
        let families = held.contains(.function) ? nil : held.families
        if families == modifiers {
            if comboReachedAt == nil && !comboSpoiled { comboReachedAt = time }
            return nil
        }
        guard let reachedAt = comboReachedAt else {
            if families == nil || !(families ?? []).isSubset(of: modifiers) { comboSpoiled = true }
            return nil
        }
        // The exact set was held and has just changed. A release of part of it is the tap; anything else spoils it.
        comboReachedAt = nil
        let isRelease = (families ?? []).isSubset(of: modifiers) && held.rawValue & previousHeld.rawValue == held.rawValue
        comboSpoiled = true
        guard isRelease, time.timeIntervalSince(reachedAt) < maximumHoldDuration else { return nil }
        return LoneTap(pressedAt: reachedAt, releasedAt: time)
    }
}
