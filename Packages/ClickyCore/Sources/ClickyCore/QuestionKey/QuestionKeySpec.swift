import Foundation

/// The four modifier kinds, side-agnostic. A combination key matches these without caring which side was used.
public enum ModifierFamily: String, CaseIterable, Comparable, Sendable {
    case control, option, shift, command

    /// macOS order: Control, Option, Shift, Command.
    private var sortRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: ModifierFamily, b: ModifierFamily) -> Bool { a.sortRank < b.sortRank }

    /// The symbol macOS prints for the key.
    public var symbol: String {
        switch self {
        case .control: return "\u{2303}"
        case .option: return "\u{2325}"
        case .shift: return "\u{21E7}"
        case .command: return "\u{2318}"
        }
    }

    public var displayName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }
}

/// One physical modifier key, left and right told apart.
public enum ModifierKey: String, CaseIterable, Sendable {
    case leftControl, rightControl, leftOption, rightOption, leftShift, rightShift, leftCommand, rightCommand

    public var family: ModifierFamily {
        switch self {
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftCommand, .rightCommand: return .command
        }
    }

    public var keyCode: UInt16 {
        switch self {
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftCommand: return 55
        case .rightCommand: return 54
        }
    }

    /// The device-dependent bit macOS sets in an event's flags while this key is down (IOKit NX_DEVICE*KEYMASK).
    public var heldBit: HeldModifiers {
        switch self {
        case .leftControl: return HeldModifiers(rawValue: 0x1)
        case .leftShift: return HeldModifiers(rawValue: 0x2)
        case .rightShift: return HeldModifiers(rawValue: 0x4)
        case .leftCommand: return HeldModifiers(rawValue: 0x8)
        case .rightCommand: return HeldModifiers(rawValue: 0x10)
        case .leftOption: return HeldModifiers(rawValue: 0x20)
        case .rightOption: return HeldModifiers(rawValue: 0x40)
        case .rightControl: return HeldModifiers(rawValue: 0x2000)
        }
    }

    public var sideName: String { rawValue.hasPrefix("left") ? "Left" : "Right" }

    public var displayName: String {
        "\(sideName) \(family.displayName)"
    }

    public init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }
}

/// The modifier keys that are down right now, as the device-dependent flag bits of a keyboard event.
public struct HeldModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// The Fn key. It is never part of a question key, but while it is down a press is not a lone one.
    public static let function = HeldModifiers(rawValue: 0x800000)

    private static let keyBits: HeldModifiers = ModifierKey.allCases.reduce([]) { $0.union($1.heldBit) }

    /// Reads the held keys out of a CGEvent's or NSEvent's raw flags, ignoring every other bit.
    public init(eventFlagBits: UInt64) {
        self = HeldModifiers(rawValue: eventFlagBits).intersection(Self.keyBits.union(.function))
    }

    public var keys: Set<ModifierKey> { Set(ModifierKey.allCases.filter { contains($0.heldBit) }) }
    public var families: Set<ModifierFamily> { Set(keys.map(\.family)) }
    public var withoutFunction: HeldModifiers { subtracting(.function) }
}

/// The key that starts and sends a spoken question.
public enum QuestionKeySpec: Equatable, Sendable {
    /// One modifier key tapped on its own, a specific side. Pressed together with anything else, it does not count.
    case loneModifier(ModifierKey)
    /// Modifiers held together, with one regular key (fires when the key goes down) or without (fires when the
    /// modifiers are let go after being held alone). Either side of a modifier counts.
    case combination(modifiers: Set<ModifierFamily>, keyCode: UInt16?)
    /// Specific modifier keys, sides told apart, held together with one regular key (fires when the key goes down)
    /// or without (fires like the question key's modifiers-only rule; a single modifier is a lone tap). Only the
    /// chat key uses this case; the question key never takes it.
    case sidedCombination(modifiers: Set<ModifierKey>, keyCode: UInt16?)

    public static let `default`: QuestionKeySpec = .loneModifier(.rightCommand)

    /// The chat key unless the user chose another: right Command + comma.
    public static let defaultChatKey: QuestionKeySpec = .sidedCombination(modifiers: [.rightCommand], keyCode: 43)

    /// True for the forms the chat key's recorder makes. A saved lone or family value is not a chat key.
    public var isChatKeyForm: Bool {
        if case .sidedCombination = self { return true }
        return false
    }

    /// The chat key kept in settings, read at launch: nothing, a damaged value, or a form the chat key's recorder
    /// never makes (a hand-edited or older `lone:` or `combo:` value) all give the default.
    public static func savedChatKey(encoded: String?) -> QuestionKeySpec {
        guard let encoded, let spec = QuestionKeySpec(encoded: encoded), spec.isChatKeyForm else { return .defaultChatKey }
        return spec
    }

    /// Builds a sided combination, or nil when it would fire while typing: it needs at least one modifier.
    public static func makeSidedCombination(modifiers: Set<ModifierKey>, keyCode: UInt16?) -> QuestionKeySpec? {
        guard !modifiers.isEmpty else { return nil }
        return .sidedCombination(modifiers: modifiers, keyCode: keyCode)
    }

    /// Builds a combination, or nil when it would fire while typing: a regular key needs at least one modifier,
    /// and modifiers alone need at least two.
    public static func makeCombination(modifiers: Set<ModifierFamily>, keyCode: UInt16?) -> QuestionKeySpec? {
        guard !modifiers.isEmpty, keyCode != nil || modifiers.count >= 2 else { return nil }
        return .combination(modifiers: modifiers, keyCode: keyCode)
    }

    /// True when the key press has to be hidden from the app the user is in, which needs an event tap that can
    /// remove events, not only watch them.
    public var swallowsAKey: Bool {
        switch self {
        case .combination(_, let keyCode), .sidedCombination(_, let keyCode): return keyCode != nil
        case .loneModifier: return false
        }
    }

    /// "Right Command", "Control + Option + Space", "Control + Option".
    public var displayName: String {
        switch self {
        case .loneModifier(let key):
            return key.displayName
        case .combination(let modifiers, let keyCode):
            var parts = modifiers.sorted().map(\.displayName)
            if let keyCode { parts.append(KeyCodeNames.name(for: keyCode)) }
            return parts.joined(separator: " + ")
        case .sidedCombination(let modifiers, let keyCode):
            var parts = Self.sortedByMacOSOrder(modifiers).map { "\($0.sideName) \($0.family.symbol)" }
            if let keyCode { parts.append(KeyCodeNames.name(for: keyCode)) }
            return parts.joined(separator: " ")
        }
    }

    private static func sortedByMacOSOrder(_ keys: Set<ModifierKey>) -> [ModifierKey] {
        keys.sorted { a, b in
            a.family == b.family ? a.keyCode < b.keyCode : a.family < b.family
        }
    }

    // MARK: Saved form

    /// The text kept in settings: `lone:54`, `combo:control,option:49`, `combo:control,option:-`.
    public var encoded: String {
        switch self {
        case .loneModifier(let key):
            return "lone:\(key.keyCode)"
        case .combination(let modifiers, let keyCode):
            let names = modifiers.sorted().map(\.rawValue).joined(separator: ",")
            return "combo:\(names):\(keyCode.map(String.init) ?? "-")"
        case .sidedCombination(let modifiers, let keyCode):
            let names = Self.sortedByMacOSOrder(modifiers).map(\.rawValue).joined(separator: ",")
            return "sided:\(names):\(keyCode.map(String.init) ?? "")"
        }
    }

    /// Nil for anything that is not a valid saved form, so a damaged value falls back to the default.
    public init?(encoded: String) {
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "lone":
            guard parts.count == 2, let code = UInt16(parts[1]), let key = ModifierKey(keyCode: code) else { return nil }
            self = .loneModifier(key)
        case "combo":
            guard parts.count == 3 else { return nil }
            let families = parts[1].split(separator: ",").compactMap { ModifierFamily(rawValue: String($0)) }
            guard families.count == parts[1].split(separator: ",").count else { return nil }
            let keyCode: UInt16?
            if parts[2] == "-" {
                keyCode = nil
            } else if let code = UInt16(parts[2]) {
                keyCode = code
            } else {
                return nil
            }
            guard let spec = Self.makeCombination(modifiers: Set(families), keyCode: keyCode) else { return nil }
            self = spec
        case "sided":
            guard parts.count == 3 else { return nil }
            let names = parts[1].split(separator: ",").map(String.init)
            let keys = names.compactMap { ModifierKey(rawValue: $0) }
            guard keys.count == names.count else { return nil }
            let keyCode: UInt16?
            if parts[2].isEmpty {
                keyCode = nil
            } else if let code = UInt16(parts[2]) {
                keyCode = code
            } else {
                return nil
            }
            guard let spec = Self.makeSidedCombination(modifiers: Set(keys), keyCode: keyCode) else { return nil }
            self = spec
        default:
            return nil
        }
    }
}

/// Names for the regular keys a combination may use (US layout key codes).
enum KeyCodeNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape", 64: "F17", 71: "Clear", 76: "Enter",
        79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
        116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]

    static func name(for keyCode: UInt16) -> String { names[keyCode] ?? "Key \(keyCode)" }
}
