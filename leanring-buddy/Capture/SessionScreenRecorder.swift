//
//  SessionScreenRecorder.swift
//  leanring-buddy
//
//  Saves screenshots of every display during a session: at session start, on each
//  question, on app or window switches, and when the screen changes clearly. Runs
//  on the Mac only; nothing is read from the screenshots and nothing is sent anywhere.
//

import ClickyCore
import CoreGraphics
import Foundation

enum SessionScreenRecorderError: Error {
    case notRunning
}

actor SessionScreenRecorder {

    private let shotsDirectory: URL
    private let savePolicy = CaptureSavePolicy()
    private let samplingIntervalSeconds: Double = 1.0

    private var onShotGroup: (@Sendable (ShotGroup) -> Void)?
    private var isRunning = false
    private var nextGroupID = 1
    private var lastSavedGroup: ShotGroup?
    private var lastSaveTime: Date?
    private var currentAppName = ""
    private var currentWindowTitle: String?
    /// Bumped on every focus change so a deferred save can tell whether focus moved on.
    private var focusChangeCount = 0
    private var isAutomaticSaveInFlight = false
    private var samplingTask: Task<Void, Never>?
    private var deferredSaveTask: Task<Void, Never>?

    init(shotsDirectory: URL) {
        self.shotsDirectory = shotsDirectory
    }

    /// Saves a `.sessionStart` group, then watches for changes about once a second.
    /// Set the starting app with `noteFocusChanged` first when you know it.
    func start(onShotGroup: @escaping @Sendable (ShotGroup) -> Void) async throws {
        await stop()
        try FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        self.onShotGroup = onShotGroup
        isRunning = true
        nextGroupID = 1
        lastSavedGroup = nil
        lastSaveTime = nil

        do {
            _ = try await saveFullCapture(reason: .sessionStart)
        } catch {
            await stop()
            throw error
        }

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000))
                if Task.isCancelled { break }
                await self?.checkForScreenChange()
            }
        }
    }

    /// A fresh capture of every display right now, delivered through `onShotGroup` too.
    func captureForQuestion() async throws -> ShotGroup {
        guard isRunning else { throw SessionScreenRecorderError.notRunning }
        return try await saveFullCapture(reason: .question)
    }

    /// Call when the frontmost app or window changes. Saves now, or after the two-second
    /// quiet period; a deferred save is dropped if focus moves on again before it runs.
    func noteFocusChanged(appName: String, windowTitle: String?, isAppSwitch: Bool) {
        currentAppName = appName
        currentWindowTitle = windowTitle
        focusChangeCount += 1
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        guard isRunning else { return }

        let reason: ShotReason = isAppSwitch ? .appSwitch : .windowSwitch
        let decision = savePolicy.decide(reason: reason, now: Date(), lastSaveTime: lastSaveTime,
                                         differenceFromLastSaved: nil)
        switch decision {
        case .saveNow:
            saveAutomatically(reason: reason)
        case .saveAt(let saveDate):
            let focusCountWhenScheduled = focusChangeCount
            deferredSaveTask = Task { [weak self] in
                let secondsToWait = max(0, saveDate.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(secondsToWait * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.runDeferredSave(reason: reason, focusCountWhenScheduled: focusCountWhenScheduled)
            }
        case .skip:
            break
        }
    }

    /// Stops sampling at once. A capture already under way is thrown away.
    func stop() async {
        isRunning = false
        samplingTask?.cancel()
        samplingTask = nil
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        onShotGroup = nil
    }

    // MARK: - Saving

    private func runDeferredSave(reason: ShotReason, focusCountWhenScheduled: Int) {
        guard isRunning, focusChangeCount == focusCountWhenScheduled else { return }
        saveAutomatically(reason: reason)
    }

    /// Runs a save in the background without blocking the caller; a failure is dropped
    /// because the next change or sample tries again.
    private func saveAutomatically(reason: ShotReason) {
        guard !isAutomaticSaveInFlight else {
            // A save is already under way; a switch must not be lost, so retry shortly.
            if reason != .screenChange {
                let focusCountWhenScheduled = focusChangeCount
                deferredSaveTask?.cancel()
                deferredSaveTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                    await self?.runDeferredSave(reason: reason, focusCountWhenScheduled: focusCountWhenScheduled)
                }
            }
            return
        }
        isAutomaticSaveInFlight = true
        Task {
            _ = try? await saveFullCapture(reason: reason)
            isAutomaticSaveInFlight = false
        }
    }

    private func checkForScreenChange() async {
        guard isRunning, !isAutomaticSaveInFlight, let lastSavedGroup else { return }
        // Cheap early exit inside the quiet period: no capture needed to know it would be skipped.
        let quietPeriodDecision = savePolicy.decide(reason: .screenChange, now: Date(), lastSaveTime: lastSaveTime,
                                                    differenceFromLastSaved: 1.0)
        guard quietPeriodDecision != .skip else { return }

        isAutomaticSaveInFlight = true
        defer { isAutomaticSaveInFlight = false }

        guard let sampledDisplays = try? await CompanionScreenCaptureUtility.captureAllDisplays(
            longSidePixels: CompanionScreenCaptureUtility.changeDetectionLongSidePixels
        ), isRunning else { return }

        let sampledGroup = ShotGroup(
            id: 0, capturedAt: Date(), reason: .screenChange, appName: currentAppName, windowTitle: currentWindowTitle,
            shots: sampledDisplays.map { display in
                DisplayShot(fileName: "", screenNumber: display.screenNumber, isCursorScreen: display.isCursorScreen,
                            pixelWidth: display.image.width, pixelHeight: display.image.height,
                            displayFrameInPoints: display.displayFrameInPoints,
                            thumbnail: ThumbnailSignature.make(from: display.image))
            }
        )
        let difference = sampledGroup.maximumDifference(from: lastSavedGroup)
        let decision = savePolicy.decide(reason: .screenChange, now: Date(), lastSaveTime: lastSaveTime,
                                         differenceFromLastSaved: difference)
        guard decision == .saveNow else { return }
        _ = try? await saveFullCapture(reason: .screenChange)
    }

    /// Captures every display at the size sent to the AI, writes the JPEGs and reports the group.
    private func saveFullCapture(reason: ShotReason) async throws -> ShotGroup {
        let capturedDisplays = try await CompanionScreenCaptureUtility.captureAllDisplays(
            longSidePixels: CompanionScreenCaptureUtility.sentImageLongSidePixels
        )
        // Questions are allowed while a stop races; automatic saves must not deliver after stop.
        if reason != .question && reason != .sessionStart && !isRunning { throw SessionScreenRecorderError.notRunning }

        // The id is taken only now, after the capture, so ids run in save order.
        let groupID = nextGroupID
        nextGroupID += 1

        var displayShots: [DisplayShot] = []
        for display in capturedDisplays {
            let encodedScreenshot = try ScreenshotJPEGEncoder.encode(display.image)
            let fileName = ShotFileNaming.fileName(groupID: groupID, screenNumber: display.screenNumber)
            try encodedScreenshot.jpegData.write(to: shotsDirectory.appendingPathComponent(fileName), options: .atomic)
            displayShots.append(DisplayShot(
                fileName: fileName,
                screenNumber: display.screenNumber,
                isCursorScreen: display.isCursorScreen,
                pixelWidth: encodedScreenshot.pixelWidth,
                pixelHeight: encodedScreenshot.pixelHeight,
                displayFrameInPoints: display.displayFrameInPoints,
                thumbnail: ThumbnailSignature.make(from: display.image)
            ))
        }

        let group = ShotGroup(id: groupID, capturedAt: Date(), reason: reason, appName: currentAppName,
                              windowTitle: currentWindowTitle, shots: displayShots)
        lastSavedGroup = group
        lastSaveTime = group.capturedAt
        onShotGroup?(group)
        return group
    }
}
