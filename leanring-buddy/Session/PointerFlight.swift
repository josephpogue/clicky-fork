//
//  PointerFlight.swift
//  leanring-buddy
//
//  Flies the blue pointer to the spot an answer named. The overlay windows
//  (one per display) exist only while a flight runs: they are created when
//  an answer points somewhere and removed when the pointer has flown back to
//  the cursor, so nothing sits on screen between answers.
//

import AppKit
import ClickyCore
import Combine
import Foundation

@MainActor
final class PointerFlightController: ObservableObject {
    /// Where to fly, in global AppKit coordinates. Observed by each display's overlay view.
    @Published private(set) var targetLocation: CGPoint?
    /// The frame of the display that spot is on, so only that display's overlay animates.
    @Published private(set) var targetDisplayFrame: CGRect?
    /// What the pointer says on arrival. Nil lets the overlay pick its own short phrase.
    @Published private(set) var targetLabel: String?

    /// The token of the flight that was asked to return to the cursor now. The overlay that runs that flight
    /// starts its normal fly-back when this changes.
    @Published private(set) var returnToCursorRequestedFlight: Int?

    /// Where the pointer's label is while the blue triangle is away from the cursor (flying out, pointing,
    /// flying back), in global AppKit coordinates. The answer bubble rides under it. Nil when the pointer is
    /// with the cursor, so the bubble sits beside the cursor.
    private(set) var pointerLabelGlobalFrame: CGRect?
    /// The pointer triangle plus the spot it points at, in global AppKit coordinates, published with the
    /// label frame. A bubble flipped above the label stays clear of it.
    private(set) var pointerClearanceGlobalFrame: CGRect?

    /// Numbers each flight so a timer from an earlier flight cannot end or reshape a later one.
    private var flightTokens = PointerFlightTokens()
    /// The token of the flight now running, or nil when none is.
    private(set) var currentFlightToken: Int?

    private let overlayWindowManager = OverlayWindowManager()

    /// The overlay publishes the label's frame on every step of the flight.
    func publishPointerLabelFrame(_ labelGlobalFrame: CGRect?, clearance: CGRect?, flightToken: Int) {
        guard flightTokens.isCurrent(flightToken), returnToCursorRequestedFlight != flightToken else { return }
        pointerLabelGlobalFrame = labelGlobalFrame
        pointerClearanceGlobalFrame = clearance
    }

    /// Whether `flightToken` is the flight now running; the overlay's hold and return timers check this.
    func isCurrentFlight(_ flightToken: Int) -> Bool {
        flightTokens.isCurrent(flightToken)
    }

    /// Shows the overlay on every display and flies to `location`.
    func flyPointer(to location: CGPoint, onDisplayWithFrame displayFrame: CGRect, label: String?) {
        currentFlightToken = flightTokens.begin()
        pointerLabelGlobalFrame = nil
        pointerClearanceGlobalFrame = nil
        targetLocation = location
        targetDisplayFrame = displayFrame
        targetLabel = label
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, pointerFlight: self)
    }

    /// The overlay calls this when the pointer is back at the cursor. A flight that a newer one replaced, or
    /// that Stop cancelled, does nothing.
    func finishFlight(flightToken: Int) {
        guard flightTokens.finish(flightToken) else { return }
        currentFlightToken = nil
        pointerClearanceGlobalFrame = nil
        targetLocation = nil
        targetDisplayFrame = nil
        targetLabel = nil
        pointerLabelGlobalFrame = nil
        // The call comes from inside the overlay view's own animation timer, so the windows go on the next turn.
        Task { @MainActor [weak self] in
            guard let self, self.targetLocation == nil else { return }
            self.overlayWindowManager.hideOverlay()
        }
    }

    /// A new question: ends the current flight by starting its normal return to the cursor at once, with
    /// the label and clearance frames cleared so the next answer sits beside the cursor. Unlike `cancelFlight`
    /// the overlay stays up, so the blue cursor keeps showing. Does nothing when no flight is running.
    func endCurrentFlightByReturningToCursor() {
        guard let flightToken = flightTokens.requestReturnToCursor() else { return }
        pointerLabelGlobalFrame = nil
        pointerClearanceGlobalFrame = nil
        targetLabel = nil
        returnToCursorRequestedFlight = flightToken
    }

    /// Stop and quit: remove the pointer at once.
    func cancelFlight() {
        flightTokens.cancel()
        currentFlightToken = nil
        pointerClearanceGlobalFrame = nil
        targetLocation = nil
        targetDisplayFrame = nil
        targetLabel = nil
        pointerLabelGlobalFrame = nil
        returnToCursorRequestedFlight = nil
        overlayWindowManager.hideOverlay()
    }
}
