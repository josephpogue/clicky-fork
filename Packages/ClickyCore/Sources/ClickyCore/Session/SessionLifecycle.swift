import Foundation

/// Where a session is between the user pressing Start and the session being gone.
public enum SessionLifecyclePhase: Equatable, Sendable {
    case idle
    /// Start was pressed. Nothing captures yet: the session waits for speech, the microphone permission and the provider.
    case starting
    case running
    /// Stop was pressed (or Quit ended the session). The log is being written and the summary may be running.
    case stopping
}

/// What a Start waits for right now. Each step names its chat line.
public enum SessionStartStep: Equatable, Sendable {
    case preparingSessionLog
    case gettingSpeechReady
    case waitingForMicrophonePermission
    case waitingForSpeechRecognitionPermission
    case startingProvider(providerName: String)

    public var statusText: String {
        switch self {
        case .preparingSessionLog: return "Getting the session log ready"
        case .gettingSpeechReady: return "Getting speech ready"
        case .waitingForMicrophonePermission: return "Waiting for microphone permission"
        case .waitingForSpeechRecognitionPermission: return "Waiting for speech recognition permission"
        case .startingProvider(let providerName): return "Starting \(providerName)"
        }
    }
}

/// What the Start/Stop button does when pressed.
public enum SessionButtonDecision: Equatable, Sendable {
    case startSession
    case cancelStart
    case stopSession
    case ignore
}

/// What the app does when the user quits.
public enum SessionQuitDecision: Equatable, Sendable {
    /// No session work is open: quit now.
    case terminateNow
    /// Start is in progress: cancel it (nothing was captured), then quit.
    case cancelStartThenTerminate
    /// A session is running: stop it without the summary, then quit.
    case stopWithoutSummaryThenTerminate
    /// Stop is already in progress: skip its summary if still waiting, let it finish, then quit.
    case skipSummaryAndWaitForStopThenTerminate
    /// An earlier quit is already doing this: do nothing more.
    case alreadyHandled
}

/// The phase rules for one session: which phase follows which, what each action does in each phase and when
/// capture may run. A plain value, so every phase and action pair is tested without hardware.
public struct SessionLifecycle: Equatable, Sendable {
    public private(set) var phase: SessionLifecyclePhase = .idle
    public private(set) var startStep: SessionStartStep?
    public private(set) var isQuitUnderway = false

    public init() {}

    // MARK: What the screen shows

    /// The session is on and everything that captures is on. False in every other phase.
    public var isRunning: Bool { phase == .running }

    /// Screen, microphone and the question key may be on only while the session runs; they are started
    /// together at the moment Start succeeds and are off in every other phase.
    public var mayCapture: Bool { phase == .running }

    /// A tapped question key signal reaches the question flow only while running.
    public var acceptsQuestionKeySignals: Bool { phase == .running }

    /// The flow's phase updates reach the screen and the marker only while running.
    public var acceptsFlowPhaseUpdates: Bool { phase == .running }

    public var buttonTitle: String {
        switch phase {
        case .idle: return "Start session"
        case .starting: return "Starting..."
        case .running: return "Stop session"
        case .stopping: return "Stopping..."
        }
    }

    /// Only Stopping is disabled; Starting cancels.
    public var isButtonEnabled: Bool { phase != .stopping }

    public var statusLine: String {
        switch phase {
        case .idle: return "No session"
        case .starting: return startStep?.statusText ?? "Starting session"
        case .running: return "Session running"
        case .stopping: return "Stopping session"
        }
    }

    // MARK: Actions

    public func decideButtonPress() -> SessionButtonDecision {
        switch phase {
        case .idle: return .startSession
        case .starting: return .cancelStart
        case .running: return .stopSession
        case .stopping: return .ignore
        }
    }

    /// Start from anywhere but idle does nothing.
    public mutating func beginStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        startStep = nil
        return true
    }

    public mutating func advanceStart(to step: SessionStartStep) {
        guard phase == .starting else { return }
        startStep = step
    }

    /// Everything that captures has just started together.
    public mutating func finishStart() -> Bool {
        guard phase == .starting else { return false }
        phase = .running
        startStep = nil
        return true
    }

    /// Start failed or was cancelled; nothing is running.
    public mutating func endStartWithoutSession() {
        guard phase == .starting else { return }
        phase = .idle
        startStep = nil
    }

    /// Leaves running first, so no key signal or phase update passes once Stop has begun.
    public mutating func beginStop() -> Bool {
        guard phase == .running else { return false }
        phase = .stopping
        return true
    }

    public mutating func finishStop() {
        guard phase == .stopping else { return }
        phase = .idle
    }

    public mutating func requestQuit() -> SessionQuitDecision {
        if isQuitUnderway { return .alreadyHandled }
        switch phase {
        case .idle:
            return .terminateNow
        case .starting:
            isQuitUnderway = true
            return .cancelStartThenTerminate
        case .running:
            isQuitUnderway = true
            return .stopWithoutSummaryThenTerminate
        case .stopping:
            isQuitUnderway = true
            return .skipSummaryAndWaitForStopThenTerminate
        }
    }
}
