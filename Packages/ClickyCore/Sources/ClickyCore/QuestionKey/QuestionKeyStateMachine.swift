import Foundation

public enum QuestionKeySignal: Equatable, Sendable {
    case questionStarted(at: Date)
    /// The user spoke between `speechFrom` and `speechTo`.
    case sendQuestion(speechFrom: Date, speechTo: Date)
}

/// Turns lone taps into question signals: first tap starts, second tap sends, third starts again.
public struct QuestionKeyStateMachine {
    private var firstTapReleasedAt: Date?

    public init() {}

    public mutating func handleLoneTap(_ tap: LoneTap) -> QuestionKeySignal {
        if let startedAt = firstTapReleasedAt {
            firstTapReleasedAt = nil
            return .sendQuestion(speechFrom: startedAt, speechTo: tap.pressedAt)
        }
        firstTapReleasedAt = tap.releasedAt
        return .questionStarted(at: tap.releasedAt)
    }

    /// Call when the session stops so a half-finished question is forgotten.
    public mutating func reset() {
        firstTapReleasedAt = nil
    }
}
