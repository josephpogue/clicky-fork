import Foundation

/// One screenshot attached to a question, with the label the AI reads to tell screens apart.
public struct TurnImage: Sendable, Equatable {
    public var fileURL: URL
    /// e.g. "screen 1 of 2, primary focus (cursor is here), 1280x800 pixels"
    public var label: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(fileURL: URL, label: String, pixelWidth: Int, pixelHeight: Int) {
        self.fileURL = fileURL
        self.label = label
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Everything one question sends to the AI.
public struct QuestionTurn: Sendable, Equatable {
    public var questionText: String
    /// What happened since the last question, already rendered; may be empty
    public var contextNote: String
    /// Current screens first, then any earlier-moment screens, each labelled
    public var images: [TurnImage]
    /// Passages from the user's notes found on the Mac for this question, already rendered by
    /// `ClickyCore/Questions`; empty when the brain is off or nothing cleared the score floor
    public var brainNote: String

    public init(questionText: String, contextNote: String, images: [TurnImage], brainNote: String = "") {
        self.questionText = questionText
        self.contextNote = contextNote
        self.images = images
        self.brainNote = brainNote
    }
}

public struct ProviderAnswer: Sendable, Equatable {
    /// Raw answer, POINT tag included
    public var text: String
    public var model: String
    public var secondsToAnswer: Double
    /// Seconds from sending the question to the first text of the answer; nil when no text came before the end
    public var secondsToFirstText: Double?
    /// Every brain tool call made inside this answer, in order
    public var toolCalls: [BrainToolCall]
    /// Files the brain tool results named, in order, without repeats
    public var notesRead: [String]
    /// Characters of brain tool results that went into the conversation, for the conversation size limit
    public var toolResultCharacterCount: Int
    /// True when a new question, Stop or the repeat guard ended the answer early; `text` is what had arrived
    public var wasCutShort: Bool

    public init(
        text: String,
        model: String,
        secondsToAnswer: Double,
        secondsToFirstText: Double? = nil,
        toolCalls: [BrainToolCall] = [],
        notesRead: [String] = [],
        toolResultCharacterCount: Int = 0,
        wasCutShort: Bool = false
    ) {
        self.text = text
        self.model = model
        self.secondsToAnswer = secondsToAnswer
        self.secondsToFirstText = secondsToFirstText
        self.toolCalls = toolCalls
        self.notesRead = notesRead
        self.toolResultCharacterCount = toolResultCharacterCount
        self.wasCutShort = wasCutShort
    }
}

/// Every way asking a provider can fail, so the chat can say the right thing (and offer the switch when the plan runs out).
public enum ProviderFailure: Error, Equatable, Sendable {
    case cliNotFound
    case notSignedIn
    /// The CLI reports an API key or other non-subscription login
    case notSubscriptionLogin(detail: String)
    case usageLimitReached(message: String)
    case failed(message: String)
}

public struct ProviderAccountStatus: Sendable, Equatable {
    public var isSignedIn: Bool
    /// What the CLI reports (email or plan), if anything
    public var accountLabel: String?

    public init(isSignedIn: Bool, accountLabel: String?) {
        self.isSignedIn = isSignedIn
        self.accountLabel = accountLabel
    }
}

/// Asks one AI service, through its own command line tool on the user's own login.
public protocol AnswerProvider: AnyObject, Sendable {
    var providerID: ProviderID { get }
    /// Starts, or restarts, the long-lived conversation. `recap` seeds a fresh conversation with earlier questions and answers as text.
    func startConversation(instructions: String, model: String, recap: String?) async throws
    func ask(_ turn: QuestionTurn, model: String) async throws -> ProviderAnswer
    /// Asks one question and reports the answer as it arrives. `request` carries the model and, for dig deeper,
    /// a stronger effort for this question only. Returns the whole answer once it is complete or cut short.
    func answer(
        _ turn: QuestionTurn,
        request: AnswerRequest,
        progress: @escaping @Sendable (AnswerProgress) async -> Void
    ) async throws -> ProviderAnswer
    /// Ends the answer under way, if any (a new question was asked). The pending `answer` call returns what had
    /// arrived, with `wasCutShort` set. The conversation stays open for the next question.
    func stopCurrentAnswer() async
    /// True when this provider gives the model the two brain tools (the brain is on and the provider can run them).
    var supportsBrainTools: Bool { get }
    /// One text-only request outside the conversation (the summary at Stop).
    func summarize(_ text: String, instructions: String, model: String) async throws -> String
    func endConversation() async
}

/// Defaults for providers that do not stream yet: one report of the whole text at the end, nothing to stop, no tools.
public extension AnswerProvider {
    func answer(
        _ turn: QuestionTurn,
        request: AnswerRequest,
        progress: @escaping @Sendable (AnswerProgress) async -> Void
    ) async throws -> ProviderAnswer {
        let whole = try await ask(turn, model: request.model)
        await progress(.textSoFar(whole.text))
        return whole
    }

    func stopCurrentAnswer() async {}

    var supportsBrainTools: Bool { false }
}

/// Signs the user in to one AI service and reports whether it worked.
public protocol ProviderAccount: AnyObject, Sendable {
    var providerID: ProviderID { get }
    func status() async -> ProviderAccountStatus
    /// Runs the CLI's own login, which opens the browser.
    func signIn() async throws
    func signOut() async throws
    func availableModels() async -> [String]
}
