import Foundation

/// Counts what has been sent in one AI conversation, so the app knows when to start a fresh one with a recap.
public struct ConversationBudget: Equatable, Sendable {
    public static let maximumTurns = 15
    public static let maximumImages = 40

    public private(set) var turnsSent = 0
    public private(set) var imagesSent = 0

    public init() {}

    public mutating func recordTurn(imageCount: Int) {
        turnsSent += 1
        imagesSent += imageCount
    }

    public var shouldStartFresh: Bool {
        turnsSent >= Self.maximumTurns || imagesSent >= Self.maximumImages
    }

    public mutating func reset() {
        turnsSent = 0
        imagesSent = 0
    }
}
