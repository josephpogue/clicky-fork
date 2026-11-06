//
//  UIPreviewSamples.swift
//  leanring-buddy
//
//  Made-up content for the preview PNGs: one value per state the windows
//  must handle. No real account, path or project of anyone's.
//

import AppKit
import SwiftUI

@MainActor
enum UIPreviewSamples {
    private static let sessionStart = Date().addingTimeInterval(-25 * 60)

    private static func minutesIntoSession(_ minutes: Double) -> Date {
        sessionStart.addingTimeInterval(minutes * 60)
    }

    // MARK: - Chat

    private static var threeExchanges: [ChatMessage] {
        [
            ChatMessage(role: .question, text: "where's the export button", time: minutesIntoSession(2)),
            ChatMessage(
                role: .answer,
                text: "Export is in the File menu, about two thirds of the way down. It saves the selected frame as a PNG unless you pick another format.",
                time: minutesIntoSession(2.05), providerName: "Claude", model: "sonnet", secondsToAnswer: 2.4
            ),
            ChatMessage(role: .question, text: "explain more about the export options", time: minutesIntoSession(6)),
            ChatMessage(
                role: .answer,
                text: "The export panel has three parts. At the top you choose what to export: the selected frame, every frame on the page, or a slice you drew earlier. Below that is the format list, where PNG keeps transparency, JPG makes smaller files for photos, SVG keeps shapes sharp at any size and PDF is best for print. Each format has a size setting; 2x is a good default for screens with a high pixel density. The suffix box adds text to the file name, which helps when you export the same frame at several sizes. When everything looks right, the Export button at the bottom asks where to save.",
                time: minutesIntoSession(6.1), providerName: "Claude", model: "sonnet", secondsToAnswer: 5.8
            ),
            ChatMessage(role: .question, text: "where do I change the line spacing", time: minutesIntoSession(11)),
            ChatMessage(
                role: .answer,
                text: "Click the paragraph icon in the right-hand panel, then set Line height to 150%. I've pointed at the icon.",
                time: minutesIntoSession(11.04), providerName: "Claude", model: "sonnet", secondsToAnswer: 2.1, pointLabel: "Paragraph settings"
            ),
        ]
    }

    private static var followUpQuestion: ChatMessage {
        ChatMessage(role: .question, text: "and how do I make that the default for new text", time: minutesIntoSession(14))
    }

    static func chatStates() -> [(String, ChatWindowState)] {
        let latestIsLongMessages: [ChatMessage] = {
            let exchanges = threeExchanges
            return [exchanges[0], exchanges[1], exchanges[4], exchanges[5], exchanges[2], exchanges[3]]
        }()

        let usageLimitMessages = threeExchanges + [followUpQuestion]

        let switchedMessages = threeExchanges + [
            followUpQuestion,
            ChatMessage(role: .notice, text: "Switched to ChatGPT. The conversation came along.", time: minutesIntoSession(14.3)),
            ChatMessage(
                role: .answer,
                text: "Select the text, set the line height, then choose Create style from the style menu and set it as the default text style.",
                time: minutesIntoSession(14.4), providerName: "ChatGPT", model: "gpt-5", secondsToAnswer: 4.7
            ),
        ]

        return [
            ("chat-empty.png", ChatWindowState(isSessionRunning: true)),
            ("chat-three-exchanges.png", ChatWindowState(messages: threeExchanges, isSessionRunning: true)),
            ("chat-latest-long-answer.png", ChatWindowState(messages: latestIsLongMessages, isSessionRunning: true)),
            ("chat-listening.png", ChatWindowState(messages: threeExchanges, isSessionRunning: true, questionPhase: .listening(audioLevel: 0.7))),
            ("chat-transcribing.png", ChatWindowState(messages: threeExchanges, isSessionRunning: true, questionPhase: .transcribing)),
            ("chat-waiting.png", ChatWindowState(messages: threeExchanges + [followUpQuestion], isSessionRunning: true, questionPhase: .waitingForAnswer(providerName: "Claude"))),
            (
                "chat-usage-limit.png",
                ChatWindowState(
                    messages: usageLimitMessages,
                    isSessionRunning: true,
                    usageLimitOffer: UsageLimitOffer(message: "Your Claude plan has hit its usage limit. It resets at 3:00 PM.", switchToProviderName: "ChatGPT")
                )
            ),
            ("chat-switched-to-chatgpt.png", ChatWindowState(messages: switchedMessages, isSessionRunning: true, activeProviderName: "ChatGPT", activeModel: "gpt-5")),
            ("chat-session-stopped.png", ChatWindowState(messages: threeExchanges, isSessionRunning: false)),
        ]
    }

    // MARK: - Marker

    static func markerPhases() -> [(String, QuestionPhase)] {
        [
            ("marker-idle.png", .idle),
            ("marker-listening-quiet.png", .listening(audioLevel: 0.1)),
            ("marker-listening-loud.png", .listening(audioLevel: 0.9)),
            ("marker-transcribing.png", .transcribing),
            ("marker-waiting.png", .waitingForAnswer(providerName: "Claude")),
        ]
    }

    // MARK: - Settings

    static func settingsClaudeRow(isSignedIn: Bool, isBusy: Bool = false) -> ProviderSettingsRow {
        ProviderSettingsRow(
            providerName: "Claude",
            isSignedIn: isSignedIn,
            accountLabel: isSignedIn ? "you@example.com · Claude Max" : nil,
            isBusy: isBusy,
            models: isSignedIn ? ["sonnet", "opus", "haiku"] : [],
            selectedModel: "sonnet",
            measuredAnswerSeconds: isSignedIn ? 2.6 : nil
        )
    }

    static func settingsChatGPTRow(isSignedIn: Bool, isBusy: Bool = false) -> ProviderSettingsRow {
        ProviderSettingsRow(
            providerName: "ChatGPT",
            isSignedIn: isSignedIn,
            accountLabel: isSignedIn ? "you@example.com · ChatGPT Plus" : nil,
            isBusy: isBusy,
            statusMessage: isBusy ? "A browser window opened for the ChatGPT sign-in. This updates when you finish there." : nil,
            models: isSignedIn ? ["gpt-5", "gpt-5-codex", "gpt-5-mini"] : [],
            selectedModel: "gpt-5",
            measuredAnswerSeconds: isSignedIn ? 4.8 : nil
        )
    }

    static func settingsStates() -> [(String, SettingsState)] {
        let sampleNotesFolder = "/Users/sample/Notes/vault"
        return [
            ("settings-signed-out.png", SettingsState(providers: [settingsClaudeRow(isSignedIn: false), settingsChatGPTRow(isSignedIn: false)], selectedProviderName: "Claude", notesFolderPath: sampleNotesFolder)),
            ("settings-claude-signed-in.png", SettingsState(providers: [settingsClaudeRow(isSignedIn: true), settingsChatGPTRow(isSignedIn: false)], selectedProviderName: "Claude", notesFolderPath: sampleNotesFolder)),
            ("settings-signing-in.png", SettingsState(providers: [settingsClaudeRow(isSignedIn: true), settingsChatGPTRow(isSignedIn: false, isBusy: true)], selectedProviderName: "Claude", notesFolderPath: sampleNotesFolder)),
            ("settings-no-notes-folder.png", SettingsState(providers: [settingsClaudeRow(isSignedIn: true), settingsChatGPTRow(isSignedIn: true)], selectedProviderName: "ChatGPT", notesFolderPath: nil, isSummaryAtStopEnabled: false)),
        ]
    }

    // MARK: - Sessions

    static func sessionListItems() -> [SessionListItem] {
        let now = Date()
        return [
            SessionListItem(id: "session-4", title: "Export settings in the design tool", startedAt: now.addingTimeInterval(-25 * 60), durationSeconds: 24 * 60, questionCount: 6, savedProject: nil),
            SessionListItem(id: "session-3", title: "Fixing code signing in Xcode", startedAt: now.addingTimeInterval(-5 * 3600), durationSeconds: 52 * 60, questionCount: 11, savedProject: "clicky-fork"),
            SessionListItem(id: "session-2", title: "Pivot table for the garden budget", startedAt: now.addingTimeInterval(-28 * 3600), durationSeconds: 18 * 60, questionCount: 4, savedProject: "garden-planner"),
            SessionListItem(id: "session-1", title: "Router settings and a second network for guests at home", startedAt: now.addingTimeInterval(-4 * 86400), durationSeconds: 75 * 60, questionCount: 1, savedProject: nil),
        ]
    }

    /// The same session while it is still running: no summary yet, and Save waits for Stop.
    static func runningSessionDetailState(shotFileURLs: [URL]) -> SessionDetailState {
        var runningState = sessionDetailState(shotFileURLs: shotFileURLs, isSaved: false)
        runningState.summary = nil
        runningState.isFinished = false
        return runningState
    }

    static func sessionDetailState(shotFileURLs: [URL], isSaved: Bool) -> SessionDetailState {
        let rows: [SessionTimelineRow] = [
            SessionTimelineRow(time: minutesIntoSession(0), kind: .focus, text: "Design tool · Homepage hero"),
            SessionTimelineRow(time: minutesIntoSession(1.5), kind: .speech, text: "okay let's get this frame out for the review"),
            SessionTimelineRow(time: minutesIntoSession(2), kind: .question, text: "where's the export button", shotFileURL: shotFileURLs[0]),
            SessionTimelineRow(time: minutesIntoSession(2.05), kind: .answer, text: "Export is in the File menu, about two thirds of the way down. It saves the selected frame as a PNG unless you pick another format.", detail: "Claude · sonnet · 2.4 s"),
            SessionTimelineRow(time: minutesIntoSession(9), kind: .focus, text: "Finder · Downloads"),
            SessionTimelineRow(time: minutesIntoSession(11), kind: .question, text: "where do I change the line spacing", shotFileURL: shotFileURLs[1]),
            SessionTimelineRow(time: minutesIntoSession(11.04), kind: .answer, text: "Click the paragraph icon in the right-hand panel, then set Line height to 150%.", detail: "Claude · sonnet · 2.1 s · pointed at Paragraph settings", shotFileURL: shotFileURLs[2]),
            SessionTimelineRow(time: minutesIntoSession(14.02), kind: .notice, text: "Claude's usage limit was reached. Switched to ChatGPT."),
        ]
        return SessionDetailState(
            title: "Export settings in the design tool",
            startedAt: sessionStart,
            summary: "Exported the homepage hero frame for review and set the body text to 150% line height. Claude's plan ran out near the end, so the last answer came from ChatGPT.",
            rows: rows,
            savedNotePath: isSaved ? "/Users/sample/Notes/vault/_sources/sessions/export-settings.md" : nil
        )
    }

    /// Draws three stand-in screenshots (a window with a sidebar and panels)
    /// into a temp folder, so the thumbnails have real image files to show.
    static func writeSampleShots() throws -> [URL] {
        let shotsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-ui-preview-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shotsFolder, withIntermediateDirectories: true)
        let accentHues: [NSColor] = [
            NSColor(calibratedRed: 0.27, green: 0.47, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.55, alpha: 1),
        ]
        var shotFileURLs: [URL] = []
        for (shotIndex, accentHue) in accentHues.enumerated() {
            let shotImage = drawSampleShot(accentHue: accentHue, variant: shotIndex)
            guard let tiffData = shotImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { continue }
            let shotFileURL = shotsFolder.appendingPathComponent("shot-\(shotIndex + 1).png")
            try pngData.write(to: shotFileURL)
            shotFileURLs.append(shotFileURL)
        }
        return shotFileURLs
    }

    private static func drawSampleShot(accentHue: NSColor, variant: Int) -> NSImage {
        let shotSize = NSSize(width: 1280, height: 800)
        return NSImage(size: shotSize, flipped: true) { _ in
            NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: shotSize).fill()
            // Window title bar.
            NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1280, height: 52).fill()
            for (dotIndex, dotColor) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
                dotColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 20 + dotIndex * 22, y: 19, width: 13, height: 13)).fill()
            }
            // Sidebar.
            NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
            NSRect(x: 0, y: 52, width: 240, height: 748).fill()
            for rowIndex in 0..<9 {
                NSColor(calibratedWhite: rowIndex == variant + 1 ? 0.75 : 0.82, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 18, y: 80 + rowIndex * 40, width: 200 - (rowIndex % 3) * 30, height: 18), xRadius: 5, yRadius: 5).fill()
            }
            // Canvas with a hero block in the accent hue.
            accentHue.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 290, y: 110, width: 640, height: 300), xRadius: 14, yRadius: 14).fill()
            NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 330, y: 160, width: 360, height: 34), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: NSRect(x: 330, y: 214, width: 260, height: 18), xRadius: 5, yRadius: 5).fill()
            for lineIndex in 0..<5 {
                NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 290, y: 450 + lineIndex * 34, width: 600 - lineIndex * 40, height: 14), xRadius: 4, yRadius: 4).fill()
            }
            // Right-hand inspector.
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSRect(x: 980, y: 52, width: 300, height: 748).fill()
            for panelIndex in 0..<4 {
                NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 1000, y: 84 + panelIndex * 120, width: 260, height: 96), xRadius: 8, yRadius: 8).fill()
            }
            return true
        }
    }

    // MARK: - Save

    private static let sampleProjects = ["clicky-fork", "garden-planner", "home-network", "kitchen-remodel", "reading-notes", "trip-planning", "tax-records"]
    private static let sampleNotePath = "/Users/sample/Notes/vault/_sources/sessions/2026-11-05-export-settings.md"

    static func saveStates() -> [(String, SaveToVaultState)] {
        [
            ("save-choosing.png", SaveToVaultState(projects: sampleProjects, suggestedProject: "clicky-fork")),
            ("save-saving.png", SaveToVaultState(projects: sampleProjects, suggestedProject: "clicky-fork", phase: .saving)),
            ("save-saved-committed.png", SaveToVaultState(projects: sampleProjects, suggestedProject: "clicky-fork", phase: .saved(notePath: sampleNotePath, committed: true, commitError: nil))),
            (
                "save-saved-commit-error.png",
                SaveToVaultState(
                    projects: sampleProjects,
                    suggestedProject: "clicky-fork",
                    phase: .saved(notePath: sampleNotePath, committed: false, commitError: "git said: the vault has uncommitted changes in another file.")
                )
            ),
            ("save-failed.png", SaveToVaultState(projects: sampleProjects, suggestedProject: "clicky-fork", phase: .failed(message: "The notes folder can't be written to. Check that the drive is connected, then try again."))),
            ("save-notes-folder-missing.png", SaveToVaultState(projects: sampleProjects, suggestedProject: "clicky-fork", notesFolderMissing: true)),
        ]
    }
}
