//
//  WindowHosting.swift
//  leanring-buddy
//
//  Small helpers the window controllers share: hosting a SwiftUI view at a
//  fixed content size, and the names the app uses for providers.
//

import AppKit
import ClickyCore
import SwiftUI

enum WindowHosting {
    /// Hosts `rootView` in a view of exactly `contentSize`. The designer's
    /// views size themselves to the window, and a hosting view that also tries
    /// to size the window from the view's ideal size can render blank, so
    /// `sizingOptions` is emptied.
    @MainActor
    static func makeHostingView<Content: View>(rootView: Content, contentSize: CGSize) -> NSHostingView<AnyView> {
        let hostingView = NSHostingView(rootView: AnyView(rootView.environment(\.colorScheme, .dark)))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        return hostingView
    }

    /// A normal titled window the app activates for, such as Settings.
    @MainActor
    static func makeStandardWindow(title: String, contentSize: CGSize, isResizable: Bool, identifier: String) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if isResizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.center()
        return window
    }
}

extension ProviderID {
    /// The name the windows show and the settings rows use.
    var windowDisplayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    init?(windowDisplayName: String) {
        guard let match = ProviderID.allCases.first(where: { $0.windowDisplayName == windowDisplayName }) else { return nil }
        self = match
    }
}
