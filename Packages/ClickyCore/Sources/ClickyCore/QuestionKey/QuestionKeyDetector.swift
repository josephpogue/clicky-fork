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
        if case .loneModifier(let key) = spec {
            target = key
        } else if case .sidedCombination(let keys, nil) = spec, keys.count == 1, let only = keys.first {
            target = only
        } else {
            target = .rightCommand
        }
        loneDetector = LoneModifierTapDetector(targetKeyCode: target.keyCode, maximumHoldDuration: maximumHoldDuration)
    }

    public mutating func handle(_ input: QuestionKeyInput) -> QuestionKeyDetection {
        switch spec {
        case .loneModifier(let key):
            return QuestionKeyDetection(tap: handleLone(input, key: key))
        case .combination(let modifiers, let keyCode):
            let match = ModifierMatch.families(modifiers)
            if let keyCode { return handleKeyCombination(input, match: match, keyCode: keyCode) }
            return QuestionKeyDetection(tap: handleModifiersOnly(input, match: match))
        case .sidedCombination(let modifiers, let keyCode):
            let match = ModifierMatch.keys(modifiers)
            if let keyCode { return handleKeyCombination(input, match: match, keyCode: keyCode, sided: true) }
            if modifiers.count == 1, let only = modifiers.first {
                return QuestionKeyDetection(tap: handleLone(input, key: only))
            }
            return QuestionKeyDetection(tap: handleModifiersOnly(input, match: match))
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

    private mutating func handleKeyCombination(_ input: QuestionKeyInput, match: ModifierMatch, keyCode: UInt16, sided: Bool = false) -> QuestionKeyDetection {
        switch input {
        case let .keyDown(code, held, isRepeat, time):
            // Sided keys also hide the repeats of a key still down after its modifiers were let go, or the
            // app would type the key.
            if sided, isRepeat, code == keyCode, swallowingKeyUp == keyCode { return QuestionKeyDetection(swallowEvent: true) }
            guard code == keyCode, match.isExactly(held.withoutFunction) else {
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

    private mutating func handleModifiersOnly(_ input: QuestionKeyInput, match: ModifierMatch) -> LoneTap? {
        switch input {
        case let .modifiersChanged(held, time):
            return handleModifiersOnlyChange(held: held, match: match, time: time)
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

    private mutating func handleModifiersOnlyChange(held: HeldModifiers, match: ModifierMatch, time: Date) -> LoneTap? {
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
        let heldNames: Set<String>? = held.contains(.function) ? nil : match.names(of: held)
        if heldNames == match.required {
            if comboReachedAt == nil && !comboSpoiled { comboReachedAt = time }
            return nil
        }
        guard let reachedAt = comboReachedAt else {
            if heldNames == nil || !(heldNames ?? []).isSubset(of: match.required) { comboSpoiled = true }
            return nil
        }
        // The exact set was held and has just changed. A release of part of it is the tap; anything else spoils it.
        comboReachedAt = nil
        let isRelease = (heldNames ?? []).isSubset(of: match.required) && held.rawValue & previousHeld.rawValue == held.rawValue
        comboSpoiled = true
        guard isRelease, time.timeIntervalSince(reachedAt) < maximumHoldDuration else { return nil }
        return LoneTap(pressedAt: reachedAt, releasedAt: time)
    }
}

/// What a held set of modifiers has to equal for a key to fire: either side of each modifier (families) or
/// specific sided keys. Both reduce to a set of names, so one piece of logic serves both.
struct ModifierMatch {
    let required: Set<String>
    private let sided: Bool

    static func families(_ families: Set<ModifierFamily>) -> ModifierMatch {
        ModifierMatch(required: Set(families.map(\.rawValue)), sided: false)
    }

    static func keys(_ keys: Set<ModifierKey>) -> ModifierMatch {
        ModifierMatch(required: Set(keys.map(\.rawValue)), sided: true)
    }

    func names(of held: HeldModifiers) -> Set<String> {
        sided ? Set(held.keys.map(\.rawValue)) : Set(held.families.map(\.rawValue))
    }

    func isExactly(_ held: HeldModifiers) -> Bool { names(of: held) == required }
}
