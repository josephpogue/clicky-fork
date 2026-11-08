//
//  QuestionKeyMonitor.swift
//  leanring-buddy
//
//  Watches system-wide for the question key (right Command unless the user chose
//  another) and the chat key (right Command + comma unless chosen) using one CGEvent
//  tap, and turns pairs of question-key presses into question signals and each
//  chat-key press into onChatKeyPressed. The tap only watches, except when a key
//  includes a regular key (the chat key by default): that tap can also remove the
//  key press so it does not type into the user's app. Both keys see every event
//  before anything is removed. A chat key that overlaps the question key is ignored
//  (TwoKeyDetector), so the question key always wins.
//  Installs nothing until start() is called, so nothing is observed outside a session.
//
//  The tap runs on its own thread (QuestionKeyTapWorker). An event-removing tap makes
//  every keystroke and click in every app wait for its callback, so the callback must
//  never wait for this app's main thread.
//

import AppKit
import ClickyCore
import CoreGraphics
import Foundation

@MainActor
final class QuestionKeyMonitor {
    var onSignal: ((QuestionKeySignal) -> Void)?
    /// Called on the main actor each time the chat key is pressed during a session.
    var onChatKeyPressed: (() -> Void)?

    /// The running tap thread; nil outside a session. Only its start and stop wait for it; every other change
    /// is handed to it without waiting.
    private var worker: QuestionKeyTapWorker?
    /// Names the current worker, so a signal queued for a stopped worker is dropped when it reaches the main actor.
    private var currentWorkerToken = UUID()

    /// The keys as chosen. The worker gets its own copy and every later change.
    private var questionKey: QuestionKeySpec = .default
    private var chatKey: QuestionKeySpec = .defaultChatKey

    /// While the Settings field records a new key, presses of the old key must not start a question.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { worker?.setSuspended(isSuspended) } }
    }

    deinit {
        worker?.shutDownWithoutWaiting()
    }

    /// Switches to a new chat key, also in a running session.
    func apply(chatKey newKey: QuestionKeySpec) {
        guard newKey != chatKey else { return }
        chatKey = newKey
        worker?.apply(chatKey: newKey)
    }

    /// Switches to a new question key. A half-finished question carries over: the new key sends it.
    func apply(questionKey newKey: QuestionKeySpec) {
        guard newKey != questionKey else { return }
        questionKey = newKey
        worker?.apply(questionKey: newKey)
    }

    /// Returns false when the tap cannot be created, which means Accessibility is not granted.
    @discardableResult
    func start() -> Bool {
        guard worker == nil else { return true }
        let token = UUID()
        let newWorker = QuestionKeyTapWorker(
            questionKey: questionKey,
            chatKey: chatKey,
            isSuspended: isSuspended,
            deliverSignal: { [weak self] signal in
                // From the tap thread: hand over without waiting, in order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.currentWorkerToken == token else { return }
                        self.onSignal?(signal)
                    }
                }
            },
            deliverChatKeyPress: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.currentWorkerToken == token else { return }
                        self.onChatKeyPressed?()
                    }
                }
            })
        guard newWorker.startAndInstallTap() else { return false }
        currentWorkerToken = token
        worker = newWorker
        return true
    }

    /// Removes the tap, ends its thread and forgets any half-finished question and key state. Returns once the
    /// thread has exited, so a Start right after works.
    func stop() {
        // Signals already queued for the main actor belong to the session that is ending.
        currentWorkerToken = UUID()
        worker?.shutDownAndWait()
        worker = nil
    }

    /// Forgets a first tap that was not used to start a question, so the next tap starts one.
    func forgetPendingQuestion() {
        worker?.forgetPendingQuestion()
    }
}

/// The event tap and everything it touches, on one thread of its own with its own run loop.
///
/// Ownership: `detector`, `questionKeyStateMachine`, `isSuspended`, `eventTap`, `eventTapRunLoopSource` and
/// `tapIsRemovingEvents` are read and written only on the tap thread. The main actor never touches them: it
/// queues a block on the tap thread's run loop (`performOnTapThread`), and blocks run one at a time, in the
/// order queued. That is the only way in, so there is no shared mutable state and no lock. The two
/// semaphores and `tapRunLoop` are written before the thread signals and read after it, which orders them.
nonisolated final class QuestionKeyTapWorker: @unchecked Sendable {
    private let deliverSignal: @Sendable (QuestionKeySignal) -> Void
    private let deliverChatKeyPress: @Sendable () -> Void

    // Tap thread only (after `startAndInstallTap` begins).
    private var detector: TwoKeyDetector
    private var questionKeyStateMachine = QuestionKeyStateMachine()
    private var isSuspended: Bool
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    /// Whether the running tap can remove events (a key combination with a regular key) or only watch.
    private var tapIsRemovingEvents = false
    private var keepAliveSource: CFRunLoopSource?

    private var tapRunLoop: CFRunLoop?
    private let threadReady = DispatchSemaphore(value: 0)
    private let threadExited = DispatchSemaphore(value: 0)
    /// Main-actor side only: whether the thread was started and not yet joined.
    private var threadIsRunning = false

    init(
        questionKey: QuestionKeySpec,
        chatKey: QuestionKeySpec,
        isSuspended: Bool,
        deliverSignal: @escaping @Sendable (QuestionKeySignal) -> Void,
        deliverChatKeyPress: @escaping @Sendable () -> Void
    ) {
        detector = TwoKeyDetector(questionKey: questionKey, chatKey: chatKey)
        self.isSuspended = isSuspended
        self.deliverSignal = deliverSignal
        self.deliverChatKeyPress = deliverChatKeyPress
    }

    // MARK: Called from the main actor

    /// Starts the thread and installs the tap on it. Waits for both. Returns false when the tap cannot be
    /// created (Accessibility is not granted); the thread is then already gone.
    func startAndInstallTap() -> Bool {
        let thread = Thread { [self] in runTapThread() }
        thread.name = "Clicky Fork question key tap"
        thread.qualityOfService = .userInteractive
        threadIsRunning = true
        thread.start()
        threadReady.wait()
        let installed = performOnTapThreadAndWait { [self] in installTap() }
        if !installed { shutDownAndWait() }
        return installed
    }

    /// Tears the tap down on its thread, ends the thread's run loop and waits until the thread has returned.
    func shutDownAndWait() {
        guard threadIsRunning else { return }
        threadIsRunning = false
        performOnTapThreadAndWait { [self] in tearDownOnTapThread() }
        threadExited.wait()
    }

    /// The same teardown without waiting, for a monitor that is being freed.
    func shutDownWithoutWaiting() {
        guard threadIsRunning else { return }
        threadIsRunning = false
        performOnTapThread { [self] in tearDownOnTapThread() }
    }

    func apply(questionKey newKey: QuestionKeySpec) {
        performOnTapThread { [self] in
            guard newKey != detector.questionKey else { return }
            detector.apply(questionKey: newKey)
            swapTapIfRemovalChanged()
        }
    }

    func apply(chatKey newKey: QuestionKeySpec) {
        performOnTapThread { [self] in
            guard newKey != detector.chatKey else { return }
            detector.apply(chatKey: newKey)
            swapTapIfRemovalChanged()
        }
    }

    func setSuspended(_ suspended: Bool) {
        performOnTapThread { [self] in
            guard suspended != isSuspended else { return }
            isSuspended = suspended
            detector.reset()
        }
    }

    func forgetPendingQuestion() {
        performOnTapThread { [self] in questionKeyStateMachine.reset() }
    }

    // MARK: Moving work onto the tap thread

    private func performOnTapThread(_ work: @escaping @Sendable () -> Void) {
        guard let tapRunLoop else { return }
        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(tapRunLoop)
    }

    private func performOnTapThreadAndWait<Result>(_ work: @escaping @Sendable () -> Result) -> Result {
        let box = TapThreadResultBox<Result>()
        let finished = DispatchSemaphore(value: 0)
        performOnTapThread {
            box.value = work()
            finished.signal()
        }
        finished.wait()
        return box.value!
    }

    // MARK: On the tap thread

    private func runTapThread() {
        tapRunLoop = CFRunLoopGetCurrent()
        // A run loop with nothing to watch returns at once, so give it a source that never fires. The
        // queued blocks and the tap's own source do the work.
        var context = CFRunLoopSourceContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil, equal: nil, hash: nil,
            schedule: nil, cancel: nil, perform: { _ in })
        if let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) {
            keepAliveSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        threadReady.signal()
        CFRunLoopRun()
        threadExited.signal()
    }

    private func installTap() -> Bool {
        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }
        let removesEvents = detector.swallowsAKey

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: removesEvents ? .defaultTap : .listenOnly,
            eventsOfInterest: eventMask,
            callback: questionKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0) else {
            CFMachPortInvalidate(createdEventTap)
            return false
        }

        eventTap = createdEventTap
        tapIsRemovingEvents = removesEvents
        eventTapRunLoopSource = createdRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        return true
    }

    private func removeTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    /// A key combination needs a tap that can remove events; otherwise the tap must stay watch-only.
    private func swapTapIfRemovalChanged() {
        if eventTap != nil, tapIsRemovingEvents != detector.swallowsAKey {
            removeTap()
            _ = installTap()
        }
    }

    private func tearDownOnTapThread() {
        removeTap()
        detector.reset()
        questionKeyStateMachine.reset()
        if let keepAliveSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), keepAliveSource, .commonModes)
            CFRunLoopSourceInvalidate(keepAliveSource)
            self.keepAliveSource = nil
        }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    /// Returns true when the event belongs to the key combination and must not reach the app the user is in.
    fileprivate func handleEventTap(eventType: CGEventType, event: CGEvent) -> Bool {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // Events were missed while the tap was off, so a half-seen key press must not complete a tap.
            detector.reset()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }
        guard !isSuspended else { return false }

        let now = Date()
        let held = HeldModifiers(eventFlagBits: event.flags.rawValue)
        let input: QuestionKeyInput
        switch eventType {
        case .flagsChanged:
            input = .modifiersChanged(held: held, time: now)
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            input = .keyDown(keyCode: keyCode, held: held, isRepeat: isRepeat, time: now)
        case .keyUp:
            input = .keyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), time: now)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input = .mouseButtonDown(time: now)
        default:
            return false
        }

        let detection = detector.handle(input)
        if let tap = detection.questionTap {
            deliverSignal(questionKeyStateMachine.handleLoneTap(tap))
        }
        if detection.chatPressed {
            deliverChatKeyPress()
        }
        // Only a removing tap can swallow; a watch-only tap ignores the answer anyway.
        return detection.swallowEvent
    }
}

/// Carries one result from the tap thread back to the caller that waits for it; the semaphore orders the write
/// before the read.
private nonisolated final class TapThreadResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// The tap's callback. It runs on the tap thread, where the worker's state lives.
private nonisolated func questionKeyEventTapCallback(
    proxy: CGEventTapProxy, eventType: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let worker = Unmanaged<QuestionKeyTapWorker>.fromOpaque(userInfo).takeUnretainedValue()
    let swallowEvent = worker.handleEventTap(eventType: eventType, event: event)
    return swallowEvent ? nil : Unmanaged.passUnretained(event)
}
