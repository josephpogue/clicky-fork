//
//  ChatPanelController.swift
//  leanring-buddy
//
//  The chat window: a small floating panel that shows the questions and
//  answers of the running session. It never takes keyboard focus from the
//  app the user is working in, so showing it or updating it does not
//  interrupt typing; clicking a button in it still works because a
//  non-activating panel passes mouse clicks through without activating.
//

import AppKit
import SwiftUI

/// A panel that refuses to become the key or main window, which is what keeps
/// keyboard focus in the user's own app.
private final class NonFocusStealingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ChatPanelController {
    private static let frameAutosaveName = "ClickyForkChatPanel"
    private static let contentSize = CGSize(width: 360, height: 520)
    private static let minimumContentSize = CGSize(width: 320, height: 360)
    private static let marginFromScreenEdge: CGFloat = 20

    private var panel: NSPanel?

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // orderFrontRegardless shows the panel without making the app or the
        // panel key, unlike makeKeyAndOrderFront.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NonFocusStealingPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Clicky Fork"
        panel.identifier = NSUserInterfaceItemIdentifier("chat.panel")
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating
        // Join every Space so the chat follows the user, and sit above full screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Closing only hides the panel; the session keeps running.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentMinSize = Self.minimumContentSize
        panel.contentView = WindowHosting.makeHostingView(
            rootView: ChatWindowView(state: SessionCoordinator.shared.chatWindowState),
            contentSize: Self.contentSize
        )

        // A saved frame wins; the first time ever, open near the top right of
        // the display the cursor is on.
        let restoredSavedFrame = panel.setFrameUsingName(Self.frameAutosaveName)
        if !restoredSavedFrame {
            panel.setFrameOrigin(Self.firstOpenOrigin(forPanelSize: panel.frame.size))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        return panel
    }

    private static func firstOpenOrigin(forPanelSize panelSize: CGSize) -> NSPoint {
        let cursorLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(cursorLocation) } ?? NSScreen.main
        guard let visibleFrame = cursorScreen?.visibleFrame else { return .zero }
        return NSPoint(
            x: visibleFrame.maxX - panelSize.width - marginFromScreenEdge,
            y: visibleFrame.maxY - panelSize.height - marginFromScreenEdge
        )
    }
}
