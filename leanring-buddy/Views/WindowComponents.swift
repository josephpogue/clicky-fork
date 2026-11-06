//
//  WindowComponents.swift
//  leanring-buddy
//
//  Small pieces shared by the v1 windows: the button style, chips, callouts,
//  the live level bars, the spinner, the key cap and a wrapping row layout.
//

import AppKit
import SwiftUI

// MARK: - Buttons

enum ClickyWindowButtonKind {
    /// The one main action of a window: accent fill.
    case primary
    /// A supporting action: surface fill.
    case secondary
    /// Low emphasis: no fill until hovered.
    case quiet
    /// Stop or sign out: quiet at rest, red on hover so it never shouts.
    case quietDestructive
}

/// Every button in the v1 windows uses this style, so each one gets a hover
/// state, a pressed state, a dimmed disabled state and the pointing-hand
/// cursor (the cursor is skipped while disabled).
struct ClickyWindowButtonStyle: ButtonStyle {
    var kind: ClickyWindowButtonKind
    var isCompact: Bool = false
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ClickyWindowButtonBody(configuration: configuration, kind: kind, isCompact: isCompact, isFullWidth: isFullWidth)
    }
}

private struct ClickyWindowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ClickyWindowButtonKind
    let isCompact: Bool
    let isFullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: isCompact ? 12.5 : 13.5, weight: .semibold))
            .foregroundColor(foregroundColor)
            .lineLimit(1)
            .padding(.horizontal, isCompact ? 11 : 16)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .frame(height: buttonHeight)
            .background(Capsule().fill(backgroundColor))
            .overlay(PillOutline(height: buttonHeight, color: outlineColor))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .onHover { isHoveringNow in
                isHovered = isEnabled && isHoveringNow
            }
            .pointerCursor(isEnabled: isEnabled)
    }

    private var buttonHeight: CGFloat { isCompact ? 26 : 32 }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            return DS.Colors.textOnAccent
        case .secondary:
            return DS.Colors.textPrimary
        case .quiet:
            return isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .quietDestructive:
            return isHovered ? DS.Colors.destructiveText : DS.Colors.textSecondary
        }
    }

    private var backgroundColor: Color {
        let isPressed = configuration.isPressed
        switch kind {
        case .primary:
            if isPressed { return DS.Colors.blue800 }
            return isHovered ? DS.Colors.accentHover : DS.Colors.accent
        case .secondary:
            if isPressed { return DS.Colors.surface4 }
            return isHovered ? DS.Colors.surface3 : DS.Colors.surface2
        case .quiet:
            if isPressed { return DS.Colors.surface3 }
            return isHovered ? DS.Colors.surface2 : Color.clear
        case .quietDestructive:
            if isPressed { return DS.Colors.destructive.opacity(0.22) }
            return isHovered ? DS.Colors.destructiveSubtle : Color.clear
        }
    }

    private var outlineColor: Color {
        switch kind {
        case .primary:
            return Color.white.opacity(0.10)
        case .secondary:
            return DS.Colors.borderSubtle
        case .quiet:
            return isHovered ? DS.Colors.borderSubtle : DS.Colors.borderSubtle.opacity(0.7)
        case .quietDestructive:
            return isHovered ? DS.Colors.destructive.opacity(0.45) : DS.Colors.borderSubtle.opacity(0.7)
        }
    }
}

extension View {
    func clickyWindowButton(_ kind: ClickyWindowButtonKind, isCompact: Bool = false, isFullWidth: Bool = false) -> some View {
        self.buttonStyle(ClickyWindowButtonStyle(kind: kind, isCompact: isCompact, isFullWidth: isFullWidth))
    }
}

/// A row-sized button (session rows, project choices, thumbnails): the whole
/// row is the hit area, the fill lifts on hover, and the cursor is a hand.
struct ClickyRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = DS.WindowRadius.card
    var restingFill: Color = Color.clear
    var hoverFill: Color = DS.Colors.surface2

    func makeBody(configuration: Configuration) -> some View {
        ClickyRowButtonBody(configuration: configuration, cornerRadius: cornerRadius, restingFill: restingFill, hoverFill: hoverFill)
    }
}

private struct ClickyRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    let restingFill: Color
    let hoverFill: Color

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? DS.Colors.surface3 : (isHovered ? hoverFill : restingFill))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHoveringNow in
                isHovered = isEnabled && isHoveringNow
            }
            .pointerCursor(isEnabled: isEnabled)
    }
}

/// A link-like text button ("Show all"): accent text, underlined on hover.
struct WindowInlineLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WindowInlineLinkButtonBody(configuration: configuration)
    }
}

private struct WindowInlineLinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(configuration.isPressed ? DS.Colors.accent : (isHovered ? DS.Colors.blue300 : DS.Colors.accentText))
            .underline(isHovered, color: DS.Colors.blue300.opacity(0.7))
            .contentShape(Rectangle())
            .onHover { isHoveringNow in isHovered = isHoveringNow }
            .pointerCursor()
    }
}

/// A 1-point outline for a pill of known height. Drawn as a rounded
/// rectangle with an exact radius because an inset `Capsule` outline renders
/// with small flat notches at its ends in the offscreen preview path.
struct PillOutline: View {
    let height: CGFloat
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2 - 0.5, style: .circular)
            .stroke(color, lineWidth: 1)
            .padding(0.5)
    }
}

// MARK: - Chips and dots

/// A small rounded label for a state: "Signed in", "Saved", "Suggested".
struct WindowStatusChip: View {
    let text: String
    let tint: Color
    var systemImageName: String? = nil
    var showsDot: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            if let systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            Text(text)
                .font(DS.WindowText.meta)
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Callouts

enum WindowCalloutKind {
    case info
    case warning
    case error
    case success

    var tint: Color {
        switch self {
        case .info: return DS.Colors.info
        case .warning: return DS.Colors.warning
        case .error: return DS.Colors.destructiveText
        case .success: return DS.Colors.success
        }
    }

    var systemImageName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var fill: Color {
        switch self {
        case .info: return DS.Colors.info.opacity(0.08)
        case .warning: return DS.Colors.warningSubtle
        case .error: return DS.Colors.destructiveSubtle
        case .success: return DS.Colors.successSubtle
        }
    }
}

/// A tinted box with an icon for something the user should notice. The fill
/// and outline carry the hue; the text stays light so it keeps its contrast.
struct WindowCallout<Accessory: View>: View {
    let kind: WindowCalloutKind
    var title: String? = nil
    let message: String
    var messageIdentifier: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(kind.tint)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title)
                            .font(DS.WindowText.bodyEmphasis)
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    Text(message)
                        .font(DS.WindowText.body)
                        .lineSpacing(DS.WindowText.bodyLineSpacing)
                        .foregroundColor(title == nil ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifierIfPresent(messageIdentifier)
                }
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .fill(kind.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .strokeBorder(kind.tint.opacity(DS.WindowCallout.outlineOpacity), lineWidth: 1)
        )
    }
}

extension WindowCallout where Accessory == EmptyView {
    init(kind: WindowCalloutKind, title: String? = nil, message: String, messageIdentifier: String? = nil) {
        self.init(kind: kind, title: title, message: message, messageIdentifier: messageIdentifier, accessory: { EmptyView() })
    }
}

extension View {
    @ViewBuilder
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

// MARK: - Live level bars

/// Five rounded bars whose heights follow the microphone level. Each bar has
/// its own share of the level so the shape reads as a voice, not a meter.
struct ListeningLevelBars: View {
    let audioLevel: Double
    var maximumBarHeight: CGFloat = 14
    var barWidth: CGFloat = 3
    var tint: Color = DS.Colors.listeningWave

    private let barShareOfLevel: [Double] = [0.55, 0.85, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: barWidth * 0.8) {
            ForEach(barShareOfLevel.indices, id: \.self) { barIndex in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: barHeight(forBarAt: barIndex))
            }
        }
        .frame(height: maximumBarHeight)
        .animation(.easeOut(duration: 0.12), value: audioLevel)
        .accessibilityHidden(true)
    }

    private func barHeight(forBarAt barIndex: Int) -> CGFloat {
        let clampedLevel = min(max(audioLevel, 0), 1)
        // A silent mic still shows short bars so the marker never looks empty.
        let restingHeight = barWidth
        let liveHeight = CGFloat(clampedLevel * barShareOfLevel[barIndex]) * maximumBarHeight
        return max(restingHeight, liveHeight)
    }
}

// MARK: - Spinner

/// A small turning arc. Native `ProgressView` draws a grey wheel that clashes
/// with the dark ground, so the windows draw their own in the accent hue.
struct WindowSpinner: View {
    var diameter: CGFloat = 12
    var tint: Color = DS.Colors.accentText
    var lineWidth: CGFloat = 1.8

    @State private var isTurning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(isTurning ? 360 : 0))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                isTurning = true
            }
        }
        .accessibilityLabel("Working")
    }
}

// MARK: - Key cap

/// A drawn key, used where the window tells the user which key to press.
struct QuestionKeyCap: View {
    let keyLabel: String
    var isLarge: Bool = false

    var body: some View {
        HStack(spacing: isLarge ? 6 : 4) {
            Image(systemName: "command")
                .font(.system(size: isLarge ? 15 : 11, weight: .semibold))
            if let sideWord {
                Text(sideWord)
                    .font(.system(size: isLarge ? 13 : 11.5, weight: .semibold, design: .rounded))
            }
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, isLarge ? 12 : 7)
        .frame(height: isLarge ? 34 : 22)
        .background(
            RoundedRectangle(cornerRadius: isLarge ? 8 : 5, style: .continuous)
                .fill(DS.Colors.surface3)
                .shadow(color: Color.black.opacity(0.45), radius: 0.5, x: 0, y: isLarge ? 2 : 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isLarge ? 8 : 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .accessibilityLabel(keyLabel)
    }

    /// "right Command" draws as the command glyph plus "right".
    private var sideWord: String? {
        let words = keyLabel.split(separator: " ")
        guard words.count > 1 else { return nil }
        return String(words[0])
    }
}

// MARK: - Wrapping row layout

/// Lays its children left to right and wraps to a new line when the row is
/// full. Used for model choices, whose count differs per provider.
struct WrappingRowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let rowFrames = arrangeRows(subviews: subviews, availableWidth: availableWidth)
        let totalHeight = rowFrames.last.map { $0.maxY } ?? 0
        let widestRow = rowFrames.map { $0.maxX }.max() ?? 0
        return CGSize(width: proposal.width ?? widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let childFrames = arrangeRows(subviews: subviews, availableWidth: bounds.width)
        for (subviewIndex, childFrame) in childFrames.enumerated() {
            subviews[subviewIndex].place(
                at: CGPoint(x: bounds.minX + childFrame.minX, y: bounds.minY + childFrame.minY),
                proposal: ProposedViewSize(childFrame.size)
            )
        }
    }

    private func arrangeRows(subviews: Subviews, availableWidth: CGFloat) -> [CGRect] {
        var childFrames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        for subview in subviews {
            let childSize = subview.sizeThatFits(.unspecified)
            if cursorX > 0 && cursorX + childSize.width > availableWidth {
                cursorX = 0
                cursorY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }
            childFrames.append(CGRect(origin: CGPoint(x: cursorX, y: cursorY), size: childSize))
            cursorX += childSize.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, childSize.height)
        }
        return childFrames
    }
}

// MARK: - Choice pill

/// One choice in a small set (provider, model). Selected shows two changes at
/// once: accent fill and a checkmark, so the choice is never ambiguous.
struct WindowChoicePill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
            }
        }
        .buttonStyle(WindowChoicePillStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WindowChoicePillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        WindowChoicePillBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct WindowChoicePillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
            .foregroundColor(isSelected ? DS.Colors.textOnAccent : (isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                Capsule().fill(isSelected ? DS.Colors.accent : (isHovered ? DS.Colors.surface3 : DS.Colors.surface2))
            )
            .overlay(PillOutline(height: 26, color: isSelected ? Color.white.opacity(0.12) : DS.Colors.borderSubtle))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHoveringNow in
                isHovered = isEnabled && isHoveringNow
            }
            .pointerCursor(isEnabled: isEnabled)
    }
}

// MARK: - Switch

/// The settings switch, drawn so it matches the dark ground whatever the
/// window's appearance is. Keeps `Toggle` semantics for VoiceOver and tests.
struct WindowSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        WindowSwitchBody(configuration: configuration)
    }
}

private struct WindowSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Button(action: { configuration.isOn.toggle() }) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? DS.Colors.accent : (isHovered ? DS.Colors.surface4 : DS.Colors.surface3))
                        .overlay(PillOutline(height: 21, color: Color.white.opacity(0.10)))
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.3), radius: 1.5, x: 0, y: 1)
                        .padding(2)
                }
                .frame(width: 36, height: 21)
                .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isOn)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringNow in isHovered = isHoveringNow }
            .pointerCursor()
        }
    }
}

// MARK: - Time formatting

enum WindowTimeFormatting {
    /// "10:42" or "10:42 AM", following the Mac's clock setting.
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "2.4 s"
    static func seconds(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    /// "24 min", "1 h 05 min", "40 s"
    static func duration(_ durationSeconds: Double) -> String {
        let totalSeconds = Int(durationSeconds.rounded())
        if totalSeconds < 60 { return "\(totalSeconds) s" }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutesPastTheHour = totalMinutes % 60
        return String(format: "%d h %02d min", hours, minutesPastTheHour)
    }

    /// "Today, 10:42", "Yesterday, 16:05", "Mon, Nov 2, 09:10"
    static func dayAndTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(clockTime(date))" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(clockTime(date))" }
        let dayPart = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(dayPart), \(clockTime(date))"
    }
}
