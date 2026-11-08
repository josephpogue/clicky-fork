import Foundation

/// Tells whether one physical press could fire both the question key and the chat key. Settings refuses a
/// new key that does, so the two never start a question and open the chat together.
public enum KeyOverlap {
    /// What a key needs held to fire. A lone modifier is the one-key sided set.
    private enum Modifiers {
        case families(Set<ModifierFamily>)
        case keys(Set<ModifierKey>)

        func sameHeldSetCanSatisfy(_ other: Modifiers) -> Bool {
            switch (self, other) {
            case let (.families(a), .families(b)): return a == b
            case let (.keys(a), .keys(b)): return a == b
            case let (.families(f), .keys(k)), let (.keys(k), .families(f)): return Set(k.map(\.family)) == f
            }
        }
    }

    private static func parts(of spec: QuestionKeySpec) -> (modifiers: Modifiers, keyCode: UInt16?) {
        switch spec {
        case .loneModifier(let key): return (.keys([key]), nil)
        case .combination(let modifiers, let keyCode): return (.families(modifiers), keyCode)
        case .sidedCombination(let modifiers, let keyCode): return (.keys(modifiers), keyCode)
        }
    }

    /// True when some press fires both keys. Two keys with a regular key overlap on the same key with a held
    /// set both accept. Two keys without one overlap when the same held set completes both. A key with a
    /// regular key never overlaps one without: the regular key press spoils the modifiers-only or lone press
    /// (the detector marks a modifiers-only press as spoiled when any key goes down while modifiers are held).
    public static func canFireBoth(_ a: QuestionKeySpec, _ b: QuestionKeySpec) -> Bool {
        let first = parts(of: a)
        let second = parts(of: b)
        switch (first.keyCode, second.keyCode) {
        case let (x?, y?): guard x == y else { return false }
        case (nil, nil): break
        default: return false
        }
        return first.modifiers.sameHeldSetCanSatisfy(second.modifiers)
    }

    /// The refusal text for a chat key that overlaps the question key, or nil when it is fine.
    public static func refusalForChatKey(_ chat: QuestionKeySpec, question: QuestionKeySpec) -> String? {
        canFireBoth(question, chat) ? "That press would also fire the question key (\(question.displayName)). Pick a different key." : nil
    }

    /// The refusal text for a question key that overlaps the chat key, or nil when it is fine.
    public static func refusalForQuestionKey(_ questionKey: QuestionKeySpec, chat: QuestionKeySpec) -> String? {
        canFireBoth(questionKey, chat) ? "That press would also fire the chat key (\(chat.displayName)). Pick a different key." : nil
    }
}

/// What the two keys did with one event.
public struct TwoKeyDetection: Equatable {
    public var questionTap: LoneTap?
    public var chatPressed: Bool
    public var swallowEvent: Bool
}

/// The question key and the chat key on one stream of events. Both detectors see every event before anything
/// is removed, so a chat-key press also spoils a lone tap of a modifier it shares.
public struct TwoKeyDetector {
    public private(set) var questionKey: QuestionKeySpec
    public private(set) var chatKey: QuestionKeySpec
    private var question: QuestionKeyDetector
    private var chat: QuestionKeyDetector

    public init(questionKey: QuestionKeySpec, chatKey: QuestionKeySpec) {
        self.questionKey = questionKey
        self.chatKey = chatKey
        question = QuestionKeyDetector(spec: questionKey)
        chat = QuestionKeyDetector(spec: chatKey)
    }

    /// True when the tap has to be able to remove events for either key.
    public var swallowsAKey: Bool { questionKey.swallowsAKey || chatKey.swallowsAKey }

    public mutating func handle(_ input: QuestionKeyInput) -> TwoKeyDetection {
        let q = question.handle(input)
        let c = chat.handle(input)
        return TwoKeyDetection(questionTap: q.tap, chatPressed: c.tap != nil, swallowEvent: q.swallowEvent || c.swallowEvent)
    }

    /// Forgets any half-seen press, keeping both keys.
    public mutating func reset() {
        question = QuestionKeyDetector(spec: questionKey)
        chat = QuestionKeyDetector(spec: chatKey)
    }

    public mutating func apply(questionKey newKey: QuestionKeySpec) {
        questionKey = newKey
        question = QuestionKeyDetector(spec: newKey)
    }

    public mutating func apply(chatKey newKey: QuestionKeySpec) {
        chatKey = newKey
        chat = QuestionKeyDetector(spec: newKey)
    }
}
