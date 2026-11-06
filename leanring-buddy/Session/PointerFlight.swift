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

    /// Where the pointer's label is while the blue triangle is away from the cursor (flying out, pointing,
    /// flying back), in global AppKit coordinates. The answer bubble rides under it. Nil when the pointer is
    /// with the cursor, so the bubble sits beside the cursor.
    private(set) var pointerLabelGlobalFrame: CGRect?

    private let overlayWindowManager = OverlayWindowManager()

    /// The overlay publishes the label's frame on every step of the flight.
    func publishPointerLabelFrame(_ labelGlobalFrame: CGRect?) {
        pointerLabelGlobalFrame = labelGlobalFrame
    }

    /// Shows the overlay on every display and flies to `location`.
    func flyPointer(to location: CGPoint, onDisplayWithFrame displayFrame: CGRect, label: String?) {
        targetLocation = location
        targetDisplayFrame = displayFrame
        targetLabel = label
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, pointerFlight: self)
    }

    /// The overlay calls this when the pointer is back at the cursor.
    func finishFlight() {
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

    /// Stop and quit: remove the pointer at once.
    func cancelFlight() {
        targetLocation = nil
        targetDisplayFrame = nil
        targetLabel = nil
        pointerLabelGlobalFrame = nil
        overlayWindowManager.hideOverlay()
    }
}
