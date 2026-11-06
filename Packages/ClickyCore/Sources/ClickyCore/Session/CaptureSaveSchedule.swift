import Foundation

/// The 2 s save limit as the screen recorder applies it. The save time is taken when a save STARTS (a capture
/// takes a moment), and a deferred save asks again when it wakes, so two saves never land closer than the limit.
/// A question always saves at once.
public struct CaptureSaveSchedule {
    private let policy: CaptureSavePolicy
    public private(set) var lastSaveTime: Date?

    public init(policy: CaptureSavePolicy = CaptureSavePolicy()) {
        self.policy = policy
    }

    public mutating func reset() {
        lastSaveTime = nil
    }

    public func decide(reason: ShotReason, now: Date, differenceFromLastSaved: Double?) -> CaptureDecision {
        policy.decide(reason: reason, now: now, lastSaveTime: lastSaveTime, differenceFromLastSaved: differenceFromLastSaved)
    }

    /// Call when a save begins, before the capture runs.
    public mutating func noteSaveStarted(at time: Date) {
        lastSaveTime = time
    }
}
