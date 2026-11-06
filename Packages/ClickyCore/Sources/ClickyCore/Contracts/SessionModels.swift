import Foundation

/// Everything the session log records. One line of the log is one `SessionEvent`.
public enum SessionEventKind: Codable, Equatable, Sendable {
    case sessionStarted
    case focusChanged(appName: String, windowTitle: String?)
    case utterance(text: String)
    case questionStarted
    case question(text: String, shotGroupID: Int, earlierShotGroupIDs: [Int])
    case answer(text: String, provider: ProviderID, model: String, secondsToAnswer: Double, pointLabel: String?)
    case answerFailed(message: String, provider: ProviderID, model: String, usageLimitReached: Bool)
    case providerSwitched(from: ProviderID, to: ProviderID)
    case screenshot(shotGroupID: Int)
    case sessionStopped
}

/// A log event with the time it happened.
public struct SessionEvent: Codable, Equatable, Sendable {
    public var time: Date
    public var kind: SessionEventKind

    public init(time: Date, kind: SessionEventKind) {
        self.time = time
        self.kind = kind
    }
}

/// The small record kept in each session folder, enough to list past sessions without reading the whole log.
public struct SessionMetadata: Codable, Equatable, Sendable {
    /// The session folder name, "yyyy-MM-dd-HHmmss" local time
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: String?
    public var cleanedUp: Bool
    /// Relative to the vault root, once saved
    public var savedVaultNotePath: String?
    public var savedProject: String?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        summary: String? = nil,
        cleanedUp: Bool = false,
        savedVaultNotePath: String? = nil,
        savedProject: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.cleanedUp = cleanedUp
        self.savedVaultNotePath = savedVaultNotePath
        self.savedProject = savedProject
    }
}
