import Foundation

/// How an answer reaches the user, chosen in Settings under "Answer by": as text beside the cursor, read
/// aloud with a voice built into macOS, or both. Text is the default.
public enum AnswerDeliveryMode: String, Sendable, CaseIterable, Codable {
    case text
    case spoken
    case both

    /// True when the answer shows as text beside the cursor.
    public var showsText: Bool { self != .spoken }

    /// True when the answer is read aloud.
    public var speaksAloud: Bool { self != .text }
}
