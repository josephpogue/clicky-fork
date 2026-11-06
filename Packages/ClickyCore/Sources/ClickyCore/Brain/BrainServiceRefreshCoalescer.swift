import Foundation

/// The bookkeeping of the app's index refreshes, kept pure so it can be tested: one refresh runs at a time, a request
/// during a running refresh queues exactly one more run (never a line of many), and a request for the folder list that
/// is already running or already queued joins that run instead of starting another.
///
/// Runs are numbered from 1. A caller that must wait for a refresh remembers the run number it was given and waits
/// until `hasCompleted(run:)` is true.
public struct BrainServiceRefreshCoalescer: Sendable, Equatable {
    public struct Request: Sendable, Equatable {
        /// The run that covers the requested folder list.
        public var run: Int
        /// True when nothing was running, so the caller must start this run now.
        public var shouldStartNow: Bool
    }

    private var startedRunCount = 0
    private var completedRunCount = 0
    /// The folder list of the run in progress; nil when idle.
    public private(set) var runningFolders: [String]?
    /// The folder list of the one queued run; nil when none is queued.
    public private(set) var pendingFolders: [String]?

    public init() {}

    public mutating func request(folders: [String]) -> Request {
        guard runningFolders != nil else {
            startedRunCount += 1
            runningFolders = folders
            return Request(run: startedRunCount, shouldStartNow: true)
        }
        if let queuedFolders = pendingFolders {
            // Latest list wins for the one queued run; everyone waiting on it gets the newest folders.
            if queuedFolders != folders { pendingFolders = folders }
            return Request(run: startedRunCount + 1, shouldStartNow: false)
        }
        if runningFolders == folders {
            return Request(run: startedRunCount, shouldStartNow: false)
        }
        pendingFolders = folders
        return Request(run: startedRunCount + 1, shouldStartNow: false)
    }

    /// Marks the running run done. Returns the queued run to start next, or nil when idle again.
    public mutating func finishRun() -> (run: Int, folders: [String])? {
        completedRunCount = startedRunCount
        guard let queuedFolders = pendingFolders else {
            runningFolders = nil
            return nil
        }
        pendingFolders = nil
        startedRunCount += 1
        runningFolders = queuedFolders
        return (startedRunCount, queuedFolders)
    }

    public func hasCompleted(run: Int) -> Bool {
        run <= completedRunCount
    }
}
