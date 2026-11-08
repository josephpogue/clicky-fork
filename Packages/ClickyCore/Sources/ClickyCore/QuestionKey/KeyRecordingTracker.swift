import Foundation

/// Who is recording a new key in Settings. The question key and chat key sections each have a Record button;
/// only one may record at a time, and the session's keys stay suspended until none does.
public struct KeyRecordingTracker {
    public private(set) var recordingOwner: String?

    public init() {}

    /// True while any section records, which is when the session's keys must stay suspended.
    public var isRecording: Bool { recordingOwner != nil }

    /// `owner` starts recording. Returns the owner that was recording and has to be cancelled, if any.
    public mutating func begin(_ owner: String) -> String? {
        let previousOwner = recordingOwner
        recordingOwner = owner
        guard let previousOwner, previousOwner != owner else { return nil }
        return previousOwner
    }

    /// `owner` stopped recording. Does nothing when another owner took over meanwhile.
    public mutating func end(_ owner: String) {
        if recordingOwner == owner { recordingOwner = nil }
    }
}
