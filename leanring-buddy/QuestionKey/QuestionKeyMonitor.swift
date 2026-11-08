//
//  QuestionKeyMonitor.swift
//  leanring-buddy
//
//  Watches system-wide for the question key (right Command unless the user chose
//  another) using a CGEvent tap, and turns pairs of presses into question signals.
//  The tap only watches, except for a key combination that includes a regular key:
//  that tap can also remove the key press so it does not type into the user's app.
//  Installs nothing until start() is called, so nothing is observed outside a session.
//

import AppKit
import ClickyCore
import CoreGraphics
import Foundation

@MainActor
final class QuestionKeyMonitor {
    var onSignal: ((QuestionKeySignal) -> Void)?

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    /// Whether the running tap can remove events (a key combination with a regular key) or only watch.
    private var tapIsRemovingEvents = false
    private var questionKey: QuestionKeySpec = .default
    private var detector = QuestionKeyDetector(spec: .default)
    private var questionKeyStateMachine = QuestionKeyStateMachine()

    /// While the Settings field records a new key, presses of the old key must not start a question.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { detector = QuestionKeyDetector(spec: questionKey) } }
    }

    deinit {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    /// Switches to a new question key. A half-finished question carries over: the new key sends it.
    func apply(questionKey newKey: QuestionKeySpec) {
        guard newKey != questionKey else { return }
        questionKey = newKey
        detector = QuestionKeyDetector(spec: newKey)
        // A key combination needs a tap that can remove events; the others must stay watch-only.
        if eventTap != nil, tapIsRemovingEvents != newKey.swallowsAKey {
            removeTap()
            _ = installTap()
        }
    }

    /// Returns false when the tap cannot be created, which means Accessibility is not granted.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        return installTap()
    }

    private func installTap() -> Bool {
        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        // The tap callback runs on the main run loop, so it is safe to assume main-actor isolation.
        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<QuestionKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            let swallowEvent = MainActor.assumeIsolated {
                monitor.handleEventTap(eventType: eventType, event: event)
            }
            return swallowEvent ? nil : Unmanaged.passUnretained(event)
        }

        let removesEvents = questionKey.swallowsAKey

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: removesEvents ? .defaultTap : .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
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
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        return true
    }

    /// Removes the tap and forgets any half-finished question and key state.
    func stop() {
        removeTap()
        detector = QuestionKeyDetector(spec: questionKey)
        questionKeyStateMachine.reset()
    }

    private func removeTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    /// Forgets a first tap that was not used to start a question, so the next tap starts one.
    func forgetPendingQuestion() {
        questionKeyStateMachine.reset()
    }

    /// Returns true when the event belongs to the key combination and must not reach the app the user is in.
    private func handleEventTap(eventType: CGEventType, event: CGEvent) -> Bool {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // Events were missed while the tap was off, so a half-seen key press must not complete a tap.
            detector = QuestionKeyDetector(spec: questionKey)
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
        if let tap = detection.tap {
            onSignal?(questionKeyStateMachine.handleLoneTap(tap))
        }
        // Only a removing tap can swallow; a watch-only tap ignores the answer anyway.
        return detection.swallowEvent
    }
}
