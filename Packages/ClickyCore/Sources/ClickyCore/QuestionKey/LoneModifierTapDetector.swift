import Foundation

/// One keyboard or mouse event, already reduced to what tap detection needs.
/// The app layer stamps `time`, so the detector never reads a clock.
public enum KeyboardInputEvent: Equatable {
    /// A modifier key changed. `isTargetKeyDown` is whether the target key itself is
    /// down after this event. `otherModifiersHeld` is whether any modifier other than
    /// the target key is down after this event.
    case modifierFlagsChanged(keyCode: UInt16, isTargetKeyDown: Bool, otherModifiersHeld: Bool, time: Date)
    case keyDown(keyCode: UInt16, time: Date)
    case mouseButtonDown(time: Date)
}

/// A press and release of the target key with nothing else happening in between.
public struct LoneTap: Equatable {
    public let pressedAt: Date
    public let releasedAt: Date

    public init(pressedAt: Date, releasedAt: Date) {
        self.pressedAt = pressedAt
        self.releasedAt = releasedAt
    }
}

/// Recognises a lone tap of one modifier key (right Command by default).
public struct LoneModifierTapDetector {
    public static let rightCommandKeyCode: UInt16 = 54

    public let targetKeyCode: UInt16
    /// A hold at or beyond this many seconds is a long press, not a tap.
    public let maximumHoldDuration: TimeInterval

    /// Set while a clean press of the target key is in progress.
    private var pressStartedAt: Date?
    /// Set when something else happened during the press, so its release is not a tap.
    private var pressWasInterrupted = false

    public init(targetKeyCode: UInt16 = LoneModifierTapDetector.rightCommandKeyCode,
                maximumHoldDuration: TimeInterval = 1.0) {
        self.targetKeyCode = targetKeyCode
        self.maximumHoldDuration = maximumHoldDuration
    }

    public mutating func handle(_ event: KeyboardInputEvent) -> LoneTap? {
        switch event {
        case let .modifierFlagsChanged(keyCode, isTargetKeyDown, otherModifiersHeld, time):
            if keyCode == targetKeyCode {
                return handleTargetKeyChange(isDown: isTargetKeyDown, otherModifiersHeld: otherModifiersHeld, time: time)
            }
            // Another modifier going down while the target is held spoils the tap.
            if otherModifiersHeld { pressWasInterrupted = true }
            return nil
        case .keyDown, .mouseButtonDown:
            pressWasInterrupted = true
            return nil
        }
    }

    private mutating func handleTargetKeyChange(isDown: Bool, otherModifiersHeld: Bool, time: Date) -> LoneTap? {
        if isDown {
            // A press made while another modifier is held is a chord, never a tap.
            pressStartedAt = otherModifiersHeld ? nil : time
            pressWasInterrupted = false
            return nil
        }

        defer {
            pressStartedAt = nil
            pressWasInterrupted = false
        }
        guard let pressedAt = pressStartedAt, !pressWasInterrupted else { return nil }
        guard time.timeIntervalSince(pressedAt) < maximumHoldDuration else { return nil }
        return LoneTap(pressedAt: pressedAt, releasedAt: time)
    }
}
