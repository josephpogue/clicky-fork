import Foundation

/// Counts what has been sent in one AI conversation, so the app knows when to start a fresh one with a recap.
public struct ConversationBudget: Equatable, Sendable {
    public static let maximumTurns = 15
    public static let maximumImages = 40
    /// Note passages and tool results ride in the conversation too, so they count toward a fresh start.
    public static let maximumAttachedCharacters = 160_000

    public private(set) var turnsSent = 0
    public private(set) var imagesSent = 0
    public private(set) var attachedCharactersSent = 0

    public init() {}

    public mutating func recordTurn(imageCount: Int, attachedCharacterCount: Int = 0) {
        turnsSent += 1
        imagesSent += imageCount
        attachedCharactersSent += attachedCharacterCount
    }

    public var shouldStartFresh: Bool {
        turnsSent >= Self.maximumTurns || imagesSent >= Self.maximumImages
            || attachedCharactersSent >= Self.maximumAttachedCharacters
    }

    public mutating func reset() {
        turnsSent = 0
        imagesSent = 0
        attachedCharactersSent = 0
    }
}
