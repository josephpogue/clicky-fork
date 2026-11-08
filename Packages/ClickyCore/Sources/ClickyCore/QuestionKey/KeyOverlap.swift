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

    /// What Settings says under a chat key that is switched off, or nil when it works. It names the key that
    /// takes the press and what to do.
    public static func inactiveChatKeyNotice(chat: QuestionKeySpec, question: QuestionKeySpec) -> String? {
        if isChatKeyActive(chat, question: question) { return nil }
        guard chat.isChatKeyForm else {
            return "The chat key is off because it is not a key the chat key can use. Record a different chat key."
        }
        return "The chat key (\(chat.displayName)) is off: your question key (\(question.displayName)) uses the same press. Record a different chat key."
    }

    /// The refusal text for a chat key that overlaps the question key, or nil when it is fine.
    public static func refusalForChatKey(_ chat: QuestionKeySpec, question: QuestionKeySpec) -> String? {
        canFireBoth(question, chat)
            ? "That press would also fire your question key (\(question.displayName)). Press a different key for the chat key."
            : nil
    }

    /// The refusal for a Reset of the chat key: the user pressed Reset, not a key, so it says what Reset would do.
    public static func resetRefusalForChatKey(_ defaultChat: QuestionKeySpec, question: QuestionKeySpec) -> String? {
        canFireBoth(question, defaultChat)
            ? "Reset would make the chat key \(defaultChat.displayName), which also fires your question key (\(question.displayName)). Record a different question key first, or record a different chat key."
            : nil
    }

    /// The refusal for a Reset of the question key, once the chat key in use is active (as `refusalForNewQuestionKey`).
    public static func resetRefusalForQuestionKey(
        _ defaultQuestion: QuestionKeySpec, currentQuestion: QuestionKeySpec, chat: QuestionKeySpec
    ) -> String? {
        guard isChatKeyActive(chat, question: currentQuestion), canFireBoth(defaultQuestion, chat) else { return nil }
        return "Reset would make the question key \(defaultQuestion.displayName), which also fires your chat key (\(chat.displayName)). Record a different chat key first, or record a different question key."
    }

    /// The refusal text for a question key that overlaps the chat key, or nil when it is fine.
    public static func refusalForQuestionKey(_ questionKey: QuestionKeySpec, chat: QuestionKeySpec) -> String? {
        canFireBoth(questionKey, chat)
            ? "That press would also fire your chat key (\(chat.displayName)). Press a different key for the question key, or record a different chat key first."
            : nil
    }

    /// The refusal for a question key recorded now. A chat key that is already off (it clashes with the question
    /// key in use, or is not a usable form) blocks nothing: it fires nothing today, the question key wins, and
    /// Settings keeps saying the chat key is off.
    public static func refusalForNewQuestionKey(
        _ newKey: QuestionKeySpec, currentQuestion: QuestionKeySpec, chat: QuestionKeySpec
    ) -> String? {
        guard isChatKeyActive(chat, question: currentQuestion) else { return nil }
        return refusalForQuestionKey(newKey, chat: chat)
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
    /// Keys whose press this detector hid and whose release it has not yet seen. The release is hidden too, whatever
    /// happened in between (recording started, a key changed, the detectors were rebuilt).
    private var owedKeyUps: Set<UInt16> = []

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
        var swallowEvent = q.swallowEvent || c.swallowEvent
        switch input {
        case let .keyDown(keyCode, _, isRepeat, _):
            if swallowEvent {
                owedKeyUps.insert(keyCode)
            } else if owedKeyUps.contains(keyCode) {
                // A repeat of a key we hid stays hidden; a fresh press means the old release never arrived.
                if isRepeat { swallowEvent = true } else { owedKeyUps.remove(keyCode) }
            }
        case let .keyUp(keyCode, _):
            if owedKeyUps.remove(keyCode) != nil { swallowEvent = true }
        case .modifiersChanged, .mouseButtonDown:
            break
        }
        return TwoKeyDetection(questionTap: q.tap, chatPressed: c.tap != nil, swallowEvent: swallowEvent)
    }

    /// While the keys are suspended the detectors see nothing, but a release or repeat this detector owes is still
    /// hidden. True when the event must be removed.
    public mutating func swallowsWhileSuspended(_ input: QuestionKeyInput) -> Bool {
        switch input {
        case let .keyDown(keyCode, _, isRepeat, _):
            guard owedKeyUps.contains(keyCode) else { return false }
            if isRepeat { return true }
            owedKeyUps.remove(keyCode)
            return false
        case let .keyUp(keyCode, _):
            return owedKeyUps.remove(keyCode) != nil
        case .modifiersChanged, .mouseButtonDown:
            return false
        }
    }

    /// Forgets any half-seen press, keeping both keys and any release still owed.
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
