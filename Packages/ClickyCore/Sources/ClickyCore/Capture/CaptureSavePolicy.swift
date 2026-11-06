import Foundation

public enum CaptureDecision: Equatable {
    case saveNow
    /// Save at this time, if focus has not moved on by then.
    case saveAt(Date)
    case skip
}

/// Decides whether a capture moment becomes a saved screenshot group.
public struct CaptureSavePolicy {
    public var minimumSecondsBetweenSaves: Double = 2.0
    /// Fraction (0...1) of mean gray change that counts as "the screen changed clearly".
    /// Kept low enough that a window opening or a page changing triggers a save, high enough
    /// that a blinking cursor, a clock or a small spinner does not.
    public var screenChangeThreshold: Double = 0.06

    public init() {}

    public func decide(
        reason: ShotReason,
        now: Date,
        lastSaveTime: Date?,
        differenceFromLastSaved: Double?
    ) -> CaptureDecision {
        // A question and the start of a session are never held back.
        if reason == .question || reason == .sessionStart { return .saveNow }
        guard let lastSaveTime else { return .saveNow }

        let secondsSinceLastSave = now.timeIntervalSince(lastSaveTime)
        let isWithinQuietPeriod = secondsSinceLastSave < minimumSecondsBetweenSaves

        switch reason {
        case .appSwitch, .windowSwitch:
            // The first screenshot of every visit must not be lost, so wait out the quiet period.
            return isWithinQuietPeriod ? .saveAt(lastSaveTime.addingTimeInterval(minimumSecondsBetweenSaves)) : .saveNow
        case .screenChange:
            if isWithinQuietPeriod { return .skip }
            guard let differenceFromLastSaved else { return .saveNow }
            return differenceFromLastSaved >= screenChangeThreshold ? .saveNow : .skip
        case .question, .sessionStart:
            return .saveNow
        }
    }
}
