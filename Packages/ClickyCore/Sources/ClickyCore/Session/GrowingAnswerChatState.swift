import Foundation

/// Tracks the chat message of an answer that is still coming, and says what the chat should do for each report.
/// The coordinator carries the steps out on its `ChatWindowState`; this keeps the order of events testable.
///
/// Each question gets an answer token (`beginAnswer`). Every message step names the token it belongs to, so the
/// late "cut short" report of an older answer (the flow reports a new question's listening phase first) finishes
/// ITS card only: it never adds a second card and never touches the newer answer's card.
public struct GrowingAnswerChatState: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Add the answer message with this text, marked still coming.
        case appendComingMessage(token: Int, text: String)
        /// Replace the still-coming message's text.
        case replaceComingText(token: Int, text: String)
        /// End the message of answer `token` with this text (the notes read, model and timing come from the caller).
        case finishComingMessage(token: Int, text: String)
        /// Nothing was streaming: add the finished answer message as today.
        case appendFinishedMessage(text: String)
        case setCheckingNotes(Bool)
    }

    /// The last line of the chat message of an answer that ended early.
    public static func line(for reason: AnswerCutReason) -> String {
        switch reason {
        case .newerQuestion: return "(Cut short by your next question.)"
        case .failed: return "(Cut short.)"
        case .stopped: return "(Stopped.)"
        case .completedAfterNewerQuestion: return ""
        }
    }

    /// The message text of an answer that ended early: what had arrived, then the line for the reason.
    public static func cutShortText(_ visibleText: String, reason: AnswerCutReason) -> String {
        let trimmed = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = line(for: reason)
        if line.isEmpty { return trimmed }
        return trimmed.isEmpty ? line : trimmed + "\n" + line
    }

    /// An answer a newer question or Stop ended while it was coming, whose own cut-short report has not arrived yet.
    private struct RetiredAnswer: Equatable, Sendable {
        let token: Int
        let text: String
        let hasMessage: Bool
    }

    public private(set) var hasComingMessage = false
    public private(set) var comingText = ""
    private var isCheckingNotes = false
    private var lastToken = 0
    /// The newest answer, from `beginAnswer` until it finishes, is cut or is retired.
    private var currentToken: Int?
    private var retiredAnswers: [RetiredAnswer] = []

    public init() {}

    /// A question was asked: its answer gets the next token. An older answer still in flight is retired first.
    public mutating func beginAnswer() -> [Step] {
        let steps = retireCurrent(reason: .newerQuestion)
        startAnswer()
        return steps
    }

    public mutating func textReported(_ text: String) -> [Step] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let token = startAnswerIfNone()
        var steps: [Step] = []
        if isCheckingNotes {
            isCheckingNotes = false
            steps.append(.setCheckingNotes(false))
        }
        steps.append(hasComingMessage
            ? .replaceComingText(token: token, text: text) : .appendComingMessage(token: token, text: text))
        hasComingMessage = true
        comingText = text
        return steps
    }

    public mutating func checkingReported() -> [Step] {
        _ = startAnswerIfNone()
        guard !isCheckingNotes else { return [] }
        isCheckingNotes = true
        return [.setCheckingNotes(true)]
    }

    public mutating func finalAnswerReceived(_ text: String) -> [Step] {
        var steps = clearChecking()
        if hasComingMessage, let token = currentToken {
            steps.append(.finishComingMessage(token: token, text: text))
        } else {
            steps.append(.appendFinishedMessage(text: text))
        }
        endCurrent()
        return steps
    }

    /// The flow says an answer ended early. It belongs to the oldest answer that a newer question or Stop already
    /// retired; with none retired, it is the current answer's own.
    public mutating func cutShort(visibleText: String, reason: AnswerCutReason) -> [Step] {
        if !retiredAnswers.isEmpty {
            let retired = retiredAnswers.removeFirst()
            guard retired.hasMessage else { return [] }
            let text = visibleText.isEmpty ? retired.text : visibleText
            return [.finishComingMessage(token: retired.token, text: Self.cutShortText(text, reason: reason))]
        }
        guard currentToken != nil || hasComingMessage else { return [] }
        var steps = clearChecking()
        if hasComingMessage, let token = currentToken {
            let text = visibleText.isEmpty ? comingText : visibleText
            steps.append(.finishComingMessage(token: token, text: Self.cutShortText(text, reason: reason)))
        } else if !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(.appendFinishedMessage(text: Self.cutShortText(visibleText, reason: reason)))
        }
        endCurrent()
        return steps
    }

    /// A new question's listening phase: an answer still in flight ends as cut short by it, and the checking line goes.
    public mutating func newQuestionListening() -> [Step] {
        retireCurrent(reason: .newerQuestion)
    }

    /// Stop, Quit: nothing is left coming, and the checking line goes. A later `.stopped` cut finds the card ended.
    public mutating func abandon(reason: AnswerCutReason) -> [Step] {
        retireCurrent(reason: reason)
    }

    /// A notice (a failure or the usage limit) took the answer's place: a message still coming ends as "(Cut short.)"
    /// and the checking line goes, so an older path cannot leave either stuck.
    public mutating func noticeShown() -> [Step] {
        var steps = clearChecking()
        if hasComingMessage, let token = currentToken {
            steps.append(.finishComingMessage(token: token, text: Self.cutShortText(comingText, reason: .failed)))
        }
        endCurrent()
        return steps
    }

    /// A new session replaces the conversation: forget everything without touching any message.
    public mutating func reset() {
        self = GrowingAnswerChatState()
    }

    private mutating func retireCurrent(reason: AnswerCutReason) -> [Step] {
        var steps = clearChecking()
        guard let token = currentToken else {
            endCurrent()
            return steps
        }
        if hasComingMessage {
            steps.append(.finishComingMessage(token: token, text: Self.cutShortText(comingText, reason: reason)))
        }
        retiredAnswers.append(RetiredAnswer(token: token, text: comingText, hasMessage: hasComingMessage))
        endCurrent()
        return steps
    }

    private mutating func startAnswer() {
        lastToken += 1
        currentToken = lastToken
    }

    private mutating func startAnswerIfNone() -> Int {
        if currentToken == nil { startAnswer() }
        return currentToken ?? lastToken
    }

    private mutating func clearChecking() -> [Step] {
        guard isCheckingNotes else { return [] }
        isCheckingNotes = false
        return [.setCheckingNotes(false)]
    }

    private mutating func endCurrent() {
        currentToken = nil
        hasComingMessage = false
        comingText = ""
    }
}
