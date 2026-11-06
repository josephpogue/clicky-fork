import Foundation
import Testing
@testable import ClickyCore

/// Expected values come from the fix brief, finding 1: a cancelled Start leaves no session folder and no
/// notice at any step; a real failure keeps today's behaviour.
@Suite("Session start ending")
struct SessionLifecycleStartEndingTests {
    @Test func cancelRemovesTheFolderWhetherOrNotCaptureBegan() {
        for captureBegan in [false, true] {
            let ending = SessionStartEnding.decide(isCancelled: true, failureNotice: nil, captureBegan: captureBegan)
            #expect(ending.folderOutcome == .removeFolder)
            #expect(ending.noticeText == nil)
        }
    }

    @Test func cancelShowsNoNoticeEvenWhenAStepFailedBecauseOfIt() {
        let ending = SessionStartEnding.decide(isCancelled: true, failureNotice: "Screen Recording is not working.", captureBegan: true)
        #expect(ending == SessionStartEnding(folderOutcome: .removeFolder, noticeText: nil))
    }

    @Test func failureBeforeCaptureRemovesTheFolderAndShowsTheNotice() {
        let ending = SessionStartEnding.decide(isCancelled: false, failureNotice: "The AI helper could not be started.", captureBegan: false)
        #expect(ending.folderOutcome == .removeFolder)
        #expect(ending.noticeText == "The AI helper could not be started.")
    }

    @Test func failureAfterCaptureKeepsAShortSessionAndShowsTheNotice() {
        let ending = SessionStartEnding.decide(isCancelled: false, failureNotice: "The question key needs Accessibility.", captureBegan: true)
        #expect(ending.folderOutcome == .keepAsShortSession)
        #expect(ending.noticeText == "The question key needs Accessibility.")
    }

    @Test func aFailureWithoutANoticeStillEndsTheStart() {
        let ending = SessionStartEnding.decide(isCancelled: false, failureNotice: nil, captureBegan: false)
        #expect(ending == SessionStartEnding(folderOutcome: .removeFolder, noticeText: nil))
    }
}
