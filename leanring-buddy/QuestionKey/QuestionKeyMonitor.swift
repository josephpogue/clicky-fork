//
//  QuestionKeyMonitor.swift
//  leanring-buddy
//
//  Watches system-wide for a lone tap of right Command using a listen-only
//  CGEvent tap, and turns pairs of taps into question signals. Installs nothing
//  until start() is called, so nothing is observed outside a session.
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
    private var tapDetector = LoneModifierTapDetector()
    private var questionKeyStateMachine = QuestionKeyStateMachine()

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) in CGEventFlags.rawValue.
    private static let leftCommandDeviceBit: UInt64 = 0x08
    private static let rightCommandDeviceBit: UInt64 = 0x10

    deinit {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    /// Returns false when the tap cannot be created, which means Accessibility is not granted.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        // The tap callback runs on the main run loop, so it is safe to assume main-actor isolation.
        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<QuestionKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.handleEventTap(eventType: eventType, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
        eventTapRunLoopSource = createdRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        return true
    }

    /// Removes the tap and forgets any half-finished question and key state.
    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        tapDetector = LoneModifierTapDetector()
        questionKeyStateMachine.reset()
    }

    private func handleEventTap(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let now = Date()
        let keyboardInputEvent: KeyboardInputEvent
        switch eventType {
        case .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let rawFlags = event.flags.rawValue
            let isRightCommandDown = rawFlags & Self.rightCommandDeviceBit != 0
            let isLeftCommandDown = rawFlags & Self.leftCommandDeviceBit != 0
            let otherModifierFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
            let otherModifiersHeld = isLeftCommandDown || !event.flags.intersection(otherModifierFlags).isEmpty
            keyboardInputEvent = .modifierFlagsChanged(
                keyCode: keyCode,
                isTargetKeyDown: isRightCommandDown,
                otherModifiersHeld: otherModifiersHeld,
                time: now
            )
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            keyboardInputEvent = .keyDown(keyCode: keyCode, time: now)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            keyboardInputEvent = .mouseButtonDown(time: now)
        default:
            return
        }

        guard let loneTap = tapDetector.handle(keyboardInputEvent) else { return }
        onSignal?(questionKeyStateMachine.handleLoneTap(loneTap))
    }
}
