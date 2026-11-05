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

    public init(questionText: String, contextNote: String, images: [TurnImage]) {
        self.questionText = questionText
        self.contextNote = contextNote
        self.images = images
    }
}

public struct ProviderAnswer: Sendable, Equatable {
    /// Raw answer, POINT tag included
    public var text: String
    public var model: String
    public var secondsToAnswer: Double

    public init(text: String, model: String, secondsToAnswer: Double) {
        self.text = text
        self.model = model
        self.secondsToAnswer = secondsToAnswer
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
    /// One text-only request outside the conversation (the summary at Stop).
    func summarize(_ text: String, instructions: String, model: String) async throws -> String
    func endConversation() async
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
