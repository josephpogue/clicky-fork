import Foundation
import Testing
@testable import ClickyCore

@Suite("Cancellable wait")
struct CancellableWaitTests {
    @Test func returnsTheWorkResultWhenNotCancelled() async {
        let result = await CancellableWait.result { 42 }
        #expect(result == 42)
    }

    @Test func returnsNilAtOnceWhenTheCallerIsCancelledEvenIfTheWorkNeverEnds() async {
        let waiter = Task { await CancellableWait.result { () async -> Int in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        waiter.cancel()
        let result = await waiter.value
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func returnsNilWhenAlreadyCancelledBeforeWaiting() async {
        let waiter = Task { () async -> Int? in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return await CancellableWait.result { () async -> Int in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return 1
            }
        }
        waiter.cancel()
        #expect(await waiter.value == nil)
    }
}

/// The 2 s limit as the recorder applies it. Times are seconds from a fixed start (t0).
@Suite("Capture save schedule")
struct CaptureSaveScheduleTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func theSaveTimeIsTakenWhenASaveStartsSoAnEarlySwitchIsHeldBack() {
        var schedule = CaptureSaveSchedule()
        schedule.noteSaveStarted(at: t0)
        // A switch 0.5 s after the save began (the capture may not have finished): wait until t0 + 2.
        let decision = schedule.decide(reason: .appSwitch, now: t0.addingTimeInterval(0.5), differenceFromLastSaved: nil)
        #expect(decision == .saveAt(t0.addingTimeInterval(2)))
    }

    @Test func aDeferredSaveThatWakesTooEarlyIsHeldBackAgain() {
        var schedule = CaptureSaveSchedule()
        schedule.noteSaveStarted(at: t0)
        // The retry after 0.5 s asks again: still inside the 2 s window, so not "save now".
        let retry = schedule.decide(reason: .windowSwitch, now: t0.addingTimeInterval(0.5), differenceFromLastSaved: nil)
        #expect(retry != .saveNow)
        // At t0 + 2 it may save.
        let later = schedule.decide(reason: .windowSwitch, now: t0.addingTimeInterval(2), differenceFromLastSaved: nil)
        #expect(later == .saveNow)
    }

    @Test func aQuestionAlwaysSavesAtOnce() {
        var schedule = CaptureSaveSchedule()
        schedule.noteSaveStarted(at: t0)
        let decision = schedule.decide(reason: .question, now: t0.addingTimeInterval(0.1), differenceFromLastSaved: nil)
        #expect(decision == .saveNow)
    }

    @Test func aClearScreenChangeInsideTheWindowIsSkipped() {
        var schedule = CaptureSaveSchedule()
        schedule.noteSaveStarted(at: t0)
        let decision = schedule.decide(reason: .screenChange, now: t0.addingTimeInterval(1.9), differenceFromLastSaved: 0.9)
        #expect(decision == .skip)
    }

    @Test func resetForgetsTheLastSave() {
        var schedule = CaptureSaveSchedule()
        schedule.noteSaveStarted(at: t0)
        schedule.reset()
        #expect(schedule.decide(reason: .appSwitch, now: t0.addingTimeInterval(0.1), differenceFromLastSaved: nil) == .saveNow)
    }
}
