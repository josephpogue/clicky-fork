import Foundation
import Testing
@testable import ClickyCore

/// Every phase against every action. Expected values come from the fix brief (lifecycle findings 1 to 4).
@Suite("Session lifecycle phases")
struct SessionLifecycleTests {
    private func lifecycle(in phase: SessionLifecyclePhase) -> SessionLifecycle {
        var lifecycle = SessionLifecycle()
        switch phase {
        case .idle: break
        case .starting: _ = lifecycle.beginStart()
        case .running:
            _ = lifecycle.beginStart()
            _ = lifecycle.finishStart()
        case .stopping:
            _ = lifecycle.beginStart()
            _ = lifecycle.finishStart()
            _ = lifecycle.beginStop()
        }
        #expect(lifecycle.phase == phase)
        return lifecycle
    }

    private let allPhases: [SessionLifecyclePhase] = [.idle, .starting, .running, .stopping]

    @Test func pointerFlightsAreAcceptedOnlyWhileRunning() {
        for phase in allPhases {
            #expect(lifecycle(in: phase).acceptsPointerFlights == (phase == .running))
        }
    }

    // MARK: Button

    @Test func buttonPressDoesTheRightThingInEachPhase() {
        #expect(lifecycle(in: .idle).decideButtonPress() == .startSession)
        #expect(lifecycle(in: .starting).decideButtonPress() == .cancelStart)
        #expect(lifecycle(in: .running).decideButtonPress() == .stopSession)
        #expect(lifecycle(in: .stopping).decideButtonPress() == .ignore)
    }

    @Test func buttonTitleAndEnabledStateInEachPhase() {
        #expect(lifecycle(in: .idle).buttonTitle == "Start session")
        #expect(lifecycle(in: .starting).buttonTitle == "Starting...")
        #expect(lifecycle(in: .running).buttonTitle == "Stop session")
        #expect(lifecycle(in: .stopping).buttonTitle == "Stopping...")
        // Starting cancels, so it stays enabled; only Stopping is disabled.
        #expect(lifecycle(in: .idle).isButtonEnabled)
        #expect(lifecycle(in: .starting).isButtonEnabled)
        #expect(lifecycle(in: .running).isButtonEnabled)
        #expect(!lifecycle(in: .stopping).isButtonEnabled)
    }

    @Test func statusLineNamesWhatStartWaitsFor() {
        var starting = lifecycle(in: .starting)
        #expect(starting.statusLine == "Starting session")
        starting.advanceStart(to: .gettingSpeechReady)
        #expect(starting.statusLine == "Getting speech ready")
        starting.advanceStart(to: .waitingForMicrophonePermission)
        #expect(starting.statusLine == "Waiting for microphone permission")
        starting.advanceStart(to: .startingProvider(providerName: "Claude"))
        #expect(starting.statusLine == "Starting Claude")
        #expect(lifecycle(in: .idle).statusLine == "No session")
        #expect(lifecycle(in: .running).statusLine == "Session running")
        #expect(lifecycle(in: .stopping).statusLine == "Stopping session")
    }

    // MARK: Capture and signals

    @Test func nothingCapturesOrAcceptsSignalsOutsideRunning() {
        for phase in allPhases {
            let current = lifecycle(in: phase)
            let expected = phase == .running
            #expect(current.mayCapture == expected)
            #expect(current.isRunning == expected)
            #expect(current.acceptsQuestionKeySignals == expected)
            #expect(current.acceptsFlowPhaseUpdates == expected)
        }
    }

    @Test func stopLeavesRunningBeforeAnythingElse() {
        var running = lifecycle(in: .running)
        let didBeginStop = running.beginStop()
        #expect(didBeginStop)
        // Once Stop has begun, a queued tap or a late listening phase must not pass.
        #expect(!running.acceptsQuestionKeySignals)
        #expect(!running.acceptsFlowPhaseUpdates)
        #expect(!running.mayCapture)
    }

    // MARK: Transitions

    @Test func startOnlyBeginsFromIdle() {
        for phase in allPhases {
            var current = lifecycle(in: phase)
            let didBegin = current.beginStart()
            #expect(didBegin == (phase == .idle))
        }
    }

    @Test func finishStartOnlyFromStartingAndEntersRunning() {
        for phase in allPhases {
            var current = lifecycle(in: phase)
            let didFinish = current.finishStart()
            #expect(didFinish == (phase == .starting))
        }
        var starting = lifecycle(in: .starting)
        starting.advanceStart(to: .gettingSpeechReady)
        _ = starting.finishStart()
        #expect(starting.phase == .running)
        #expect(starting.startStep == nil)
    }

    @Test func aFailedOrCancelledStartReturnsToIdleOnly() {
        for phase in allPhases {
            var current = lifecycle(in: phase)
            current.endStartWithoutSession()
            #expect(current.phase == (phase == .starting ? .idle : phase))
        }
    }

    @Test func stopOnlyBeginsFromRunningAndFinishesToIdle() {
        for phase in allPhases {
            var current = lifecycle(in: phase)
            let didStop = current.beginStop()
            #expect(didStop == (phase == .running))
        }
        var stopping = lifecycle(in: .stopping)
        stopping.finishStop()
        #expect(stopping.phase == .idle)
        // Start works again after Stop is done (and only then).
        let didRestart = stopping.beginStart()
        #expect(didRestart)
    }

    @Test func finishStopIsIgnoredOutsideStopping() {
        var running = lifecycle(in: .running)
        running.finishStop()
        #expect(running.phase == .running)
    }

    @Test func stepsOnlyAdvanceWhileStarting() {
        var running = lifecycle(in: .running)
        running.advanceStart(to: .gettingSpeechReady)
        #expect(running.startStep == nil)
    }

    // MARK: Quit

    @Test func quitDoesTheRightThingInEachPhase() {
        var idle = lifecycle(in: .idle)
        let decision_idle = idle.requestQuit()
        #expect(decision_idle == .terminateNow)
        var starting = lifecycle(in: .starting)
        let decision_starting = starting.requestQuit()
        #expect(decision_starting == .cancelStartThenTerminate)
        var running = lifecycle(in: .running)
        let decision_running = running.requestQuit()
        #expect(decision_running == .stopWithoutSummaryThenTerminate)
        var stopping = lifecycle(in: .stopping)
        let decision_stopping = stopping.requestQuit()
        #expect(decision_stopping == .skipSummaryAndWaitForStopThenTerminate)
    }

    @Test func quittingTwiceHandlesItOnlyOnce() {
        for phase in [SessionLifecyclePhase.starting, .running, .stopping] {
            var current = lifecycle(in: phase)
            _ = current.requestQuit()
            let decision_current = current.requestQuit()
        #expect(decision_current == .alreadyHandled)
        }
    }

    @Test func stopPressedThenQuitSkipsTheSummary() {
        var current = lifecycle(in: .running)
        #expect(current.decideButtonPress() == .stopSession)
        let didStop = current.beginStop()
        #expect(didStop)
        // The summary is running; the user quits.
        let decision_current = current.requestQuit()
        #expect(decision_current == .skipSummaryAndWaitForStopThenTerminate)
    }
}
