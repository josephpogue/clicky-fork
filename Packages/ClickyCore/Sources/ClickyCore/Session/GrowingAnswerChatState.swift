import Foundation

/// Tracks the chat message of an answer that is still coming, and says what the chat should do for each report.
/// The coordinator carries the steps out on its `ChatWindowState`; this keeps the order of events testable.
///
/// Each question's answer number (the flow's question serial) is the token: `beginAnswer(answerNumber:)` starts it
/// and every report (text, checking line, final answer, cut short) names its number. A report for the current
/// number acts on the current card. The late "cut short" report of an ended answer finishes ITS card only, found by
/// number, so an ended answer that never reports cannot shift any other card. Text, checking and final reports for a
/// number that is not current are dropped.
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

    /// An answer a newer question or Stop ended while it was coming, whose own cut-short report may still arrive.
    private struct RetiredAnswer: Equatable, Sendable {
        let text: String
        let hasMessage: Bool
    }

    /// How many ended answers stay findable by number; an older one that never reported is forgotten.
    private static let retiredAnswersKept = 10

    public private(set) var hasComingMessage = false
    public private(set) var comingText = ""
    private var isCheckingNotes = false
    /// The newest answer's number, from `beginAnswer` until it finishes, is cut or is retired.
    private var currentToken: Int?
    private var retiredAnswers: [Int: RetiredAnswer] = [:]

    public init() {}

    /// True from `beginAnswer` until the answer finishes, is cut or is retired.
    public var isAnswerInFlight: Bool { currentToken != nil }

    /// Whether reports for `answerNumber` still belong to the answer on screen. The app drops the others entirely.
    public func isCurrent(answerNumber: Int) -> Bool {
        currentToken == answerNumber
    }

    /// A question was asked: its answer number is the token. An older answer still in flight is retired first.
    public mutating func beginAnswer(answerNumber: Int) -> [Step] {
        let steps = retireCurrent(reason: .newerQuestion)
        currentToken = answerNumber
        return steps
    }

    public mutating func textReported(answerNumber: Int, text: String) -> [Step] {
        guard isCurrent(answerNumber: answerNumber),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var steps: [Step] = []
        if isCheckingNotes {
            isCheckingNotes = false
            steps.append(.setCheckingNotes(false))
        }
        steps.append(hasComingMessage
            ? .replaceComingText(token: answerNumber, text: text)
            : .appendComingMessage(token: answerNumber, text: text))
        hasComingMessage = true
        comingText = text
        return steps
    }

    public mutating func checkingReported(answerNumber: Int) -> [Step] {
        guard isCurrent(answerNumber: answerNumber), !isCheckingNotes else { return [] }
        isCheckingNotes = true
        return [.setCheckingNotes(true)]
    }

    public mutating func finalAnswerReceived(answerNumber: Int, text: String) -> [Step] {
        guard isCurrent(answerNumber: answerNumber) else { return [] }
        var steps = clearChecking()
        if hasComingMessage {
            steps.append(.finishComingMessage(token: answerNumber, text: text))
        } else {
            steps.append(.appendFinishedMessage(text: text))
        }
        endCurrent()
        return steps
    }

    /// The flow says answer `answerNumber` ended early. For the current answer it ends the current card; for a
    /// retired one it finishes only that card (and only once); an unknown number changes nothing.
    public mutating func cutShort(answerNumber: Int, visibleText: String, reason: AnswerCutReason) -> [Step] {
        if isCurrent(answerNumber: answerNumber) {
            var steps = clearChecking()
            if hasComingMessage {
                let text = visibleText.isEmpty ? comingText : visibleText
                steps.append(.finishComingMessage(token: answerNumber, text: Self.cutShortText(text, reason: reason)))
            } else if !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                steps.append(.appendFinishedMessage(text: Self.cutShortText(visibleText, reason: reason)))
            }
            endCurrent()
            return steps
        }
        guard let retired = retiredAnswers.removeValue(forKey: answerNumber), retired.hasMessage else { return [] }
        let text = visibleText.isEmpty ? retired.text : visibleText
        return [.finishComingMessage(token: answerNumber, text: Self.cutShortText(text, reason: reason))]
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
        retiredAnswers[token] = RetiredAnswer(text: comingText, hasMessage: hasComingMessage)
        // Forget the oldest numbers beyond the last ten; a retired answer that never reports is harmless.
        while retiredAnswers.count > Self.retiredAnswersKept, let oldest = retiredAnswers.keys.min() {
            retiredAnswers.removeValue(forKey: oldest)
        }
        endCurrent()
        return steps
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
