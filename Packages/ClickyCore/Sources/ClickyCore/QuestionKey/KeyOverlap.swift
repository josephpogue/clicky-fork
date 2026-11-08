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

        /// How many modifiers a press of this key has to hold.
        var count: Int {
            switch self {
            case .families(let families): return families.count
            case .keys(let keys): return keys.count
            }
        }

        /// True when some press of `self`, completed and then let go of in part, can be built on to complete
        /// `other` without ever letting go of everything. The held keys of `self` must all be ones `other`
        /// accepts, or `other` sees a foreign modifier and refuses the whole press.
        func canGrowInto(_ other: Modifiers) -> Bool {
            switch (self, other) {
            case let (.families(a), .families(b)): return a.isSubset(of: b)
            case let (.keys(a), .keys(b)): return a.isSubset(of: b)
            case let (.families(a), .keys(b)): return a.isSubset(of: Set(b.map(\.family)))
            case let (.keys(a), .families(b)): return Set(a.map(\.family)).isSubset(of: b)
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
    /// set both accept. A key with a regular key never overlaps one without: the regular key press spoils the
    /// modifiers-only or lone press (the detector marks a modifiers-only press as spoiled when any key goes down
    /// while modifiers are held). Two keys without one overlap when the same held set completes both, or when one
    /// fires on a partial let-go and the other is then completed from what is still held, in the same hold
    /// (Left Command + Right Command, let go of Right Command, add Option, fires both that and Command + Option).
    /// A lone tap fires only on the final let-go with nothing else pressed, so it overlaps only the same key.
    public static func canFireBoth(_ a: QuestionKeySpec, _ b: QuestionKeySpec) -> Bool {
        let first = parts(of: a)
        let second = parts(of: b)
        switch (first.keyCode, second.keyCode) {
        case let (x?, y?):
            guard x == y else { return false }
            return first.modifiers.sameHeldSetCanSatisfy(second.modifiers)
        case (nil, nil):
            if first.modifiers.sameHeldSetCanSatisfy(second.modifiers) { return true }
            // A lone tap cannot be built on, and nothing built on a longer press leaves a lone tap clean.
            guard first.modifiers.count >= 2, second.modifiers.count >= 2 else { return false }
            return first.modifiers.canGrowInto(second.modifiers) || second.modifiers.canGrowInto(first.modifiers)
        default:
            return false
        }
    }

    /// True when the chat key can work next to the question key: it has the sided form its recorder makes and no
    /// press of it could also fire the question key.
    public static func isChatKeyActive(_ chat: QuestionKeySpec, question: QuestionKeySpec) -> Bool {
        chat.isChatKeyForm && !canFireBoth(question, chat)
    }

    /// What Settings says under a chat key that is switched off, or nil when it works.
    public static func inactiveChatKeyNotice(chat: QuestionKeySpec, question: QuestionKeySpec) -> String? {
        isChatKeyActive(chat, question: question) ? nil : "Your question key uses this press. Record a different chat key."
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
/// is removed, so a chat-key press also spoils a lone tap of a modifier it shares. A chat key that is not active
/// (`KeyOverlap.isChatKeyActive`) is ignored: it fires nothing and removes nothing, and the question key wins.
public struct TwoKeyDetector {
    public private(set) var questionKey: QuestionKeySpec
    /// The chat key as chosen, whether or not it is active.
    public private(set) var chatKey: QuestionKeySpec
    private var question: QuestionKeyDetector
    private var chat: QuestionKeyDetector?

    public init(questionKey: QuestionKeySpec, chatKey: QuestionKeySpec) {
        self.questionKey = questionKey
        self.chatKey = chatKey
        question = QuestionKeyDetector(spec: questionKey)
        chat = KeyOverlap.isChatKeyActive(chatKey, question: questionKey) ? QuestionKeyDetector(spec: chatKey) : nil
    }

    public var isChatKeyActive: Bool { chat != nil }

    /// True when the tap has to be able to remove events for either key.
    public var swallowsAKey: Bool { questionKey.swallowsAKey || (chat != nil && chatKey.swallowsAKey) }

    public mutating func handle(_ input: QuestionKeyInput) -> TwoKeyDetection {
        let q = question.handle(input)
        let c = chat?.handle(input) ?? QuestionKeyDetection()
        return TwoKeyDetection(questionTap: q.tap, chatPressed: c.tap != nil, swallowEvent: q.swallowEvent || c.swallowEvent)
    }

    /// Forgets any half-seen press, keeping both keys.
    public mutating func reset() {
        question = QuestionKeyDetector(spec: questionKey)
        chat = chat == nil ? nil : QuestionKeyDetector(spec: chatKey)
    }

    public mutating func apply(questionKey newKey: QuestionKeySpec) {
        questionKey = newKey
        question = QuestionKeyDetector(spec: newKey)
        refreshChatActivity()
    }

    public mutating func apply(chatKey newKey: QuestionKeySpec) {
        chatKey = newKey
        chat = nil
        refreshChatActivity()
    }

    /// Switches the chat detector on or off when the question key changed under it.
    private mutating func refreshChatActivity() {
        let shouldBeActive = KeyOverlap.isChatKeyActive(chatKey, question: questionKey)
        if shouldBeActive, chat == nil {
            chat = QuestionKeyDetector(spec: chatKey)
        } else if !shouldBeActive {
            chat = nil
        }
    }
}
