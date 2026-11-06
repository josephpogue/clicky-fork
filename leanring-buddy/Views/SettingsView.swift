//
//  SettingsView.swift
//  leanring-buddy
//
//  Settings: which plan answers, each provider's sign-in, model and measured
//  answer time, the dig-deeper model and effort, the folders Clicky can search,
//  the notes folder, the summary switch, and a short note on the three macOS
//  permissions. Choices are shown as visible pills, not drop-downs,
//  because each set is small.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var answerDeliveryState: AnswerDeliverySettingsState

    /// `init(state:)` supplies a default answer-delivery state so previews that build `SettingsView(state:)` keep compiling;
    /// the default shows Text with no voice row and never reads this Mac's voices.
    @MainActor
    init(state: SettingsState) {
        self.init(state: state, answerDeliveryState: AnswerDeliverySettingsState())
    }

    init(state: SettingsState, answerDeliveryState: AnswerDeliverySettingsState) {
        self.state = state
        self.answerDeliveryState = answerDeliveryState
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                AnswerDeliverySettingsSection(state: answerDeliveryState)
                providerSection
                DigDeeperSettingsSection(state: state)
                SearchFoldersSettingsSection(state: state)
                notesSection
                permissionsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DS.Colors.background)
        .accessibilityIdentifier("settings.window")
    }

    // MARK: - Providers

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: "Answers",
                caption: "Sign in with the plan you already pay for. A change applies from your next question."
            )

            HStack(spacing: 10) {
                Text("Answer with")
                    .font(DS.WindowText.body)
                    .foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: 6) {
                    ForEach(state.providers) { providerRow in
                        WindowChoicePill(
                            title: providerRow.providerName,
                            isSelected: providerRow.providerName == state.selectedProviderName,
                            action: { state.onSelectProvider(providerRow.providerName) }
                        )
                        // Only a signed-in provider can answer, so only it can be picked.
                        .disabled(!providerRow.isSignedIn)
                        .accessibilityIdentifier("settings.provider.\(providerRow.identifierSlug)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.provider")
            }

            VStack(spacing: 10) {
                ForEach(state.providers) { providerRow in
                    providerCard(providerRow)
                }
            }
        }
    }

    private func providerCard(_ providerRow: ProviderSettingsRow) -> some View {
        let slug = providerRow.identifierSlug
        let isAnswering = providerRow.providerName == state.selectedProviderName && providerRow.isSignedIn
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(providerRow.providerName)
                            .font(DS.WindowText.sectionTitle)
                            .foregroundColor(DS.Colors.textPrimary)
                        providerStatusChip(providerRow)
                            .accessibilityIdentifier("settings.status.\(slug)")
                    }
                    Text(providerSubtitle(providerRow))
                        .font(DS.WindowText.meta)
                        .foregroundColor(DS.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("settings.account.\(slug)")
                }
                Spacer(minLength: 8)
                providerAccountButton(providerRow)
            }

            // While the browser sign-in is open, Cancel ends it so the row is not stuck waiting.
            let isWaitingForBrowser = providerRow.isBusy && !providerRow.isSignedIn
            if providerRow.statusMessage != nil || isWaitingForBrowser {
                HStack(alignment: .center, spacing: 12) {
                    if let statusMessage = providerRow.statusMessage {
                        Text(statusMessage)
                            .font(DS.WindowText.meta)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.statusMessage.\(slug)")
                    }
                    Spacer(minLength: 8)
                    if isWaitingForBrowser {
                        Button(action: { state.onCancelSignIn(providerRow.providerName) }) {
                            Text("Cancel")
                        }
                        .clickyWindowButton(.secondary, isCompact: true)
                        .accessibilityIdentifier("settings.cancelSignIn.\(slug)")
                    }
                }
            }

            if providerRow.isSignedIn && !providerRow.models.isEmpty {
                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.5)).frame(height: 1)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Model")
                        .font(DS.WindowText.meta)
                        .foregroundColor(DS.Colors.textMuted)
                        .frame(width: 44, alignment: .leading)
                    WrappingRowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(providerRow.models, id: \.self) { modelName in
                            WindowChoicePill(
                                title: modelName,
                                isSelected: modelName == providerRow.selectedModel,
                                action: { state.onSelectModel(providerRow.providerName, modelName) }
                            )
                            .accessibilityIdentifier("settings.model.\(slug).\(modelName)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.model.\(slug)")
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Speed")
                        .font(DS.WindowText.meta)
                        .foregroundColor(DS.Colors.textMuted)
                        .frame(width: 44, alignment: .leading)
                    answerTimeLine(providerRow)
                        .accessibilityIdentifier("settings.answerTime.\(slug)")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .strokeBorder(isAnswering ? DS.Colors.accent.opacity(0.55) : DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func providerStatusChip(_ providerRow: ProviderSettingsRow) -> some View {
        if providerRow.isBusy {
            HStack(spacing: 6) {
                WindowSpinner(diameter: 10)
                Text(providerRow.isSignedIn ? "Signing out" : "Signing in")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.accentText)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(DS.Colors.accentText.opacity(0.12)))
        } else if providerRow.isSignedIn {
            WindowStatusChip(text: "Signed in", tint: DS.Colors.success, showsDot: true)
        } else {
            WindowStatusChip(text: "Not signed in", tint: DS.Colors.textMuted, showsDot: true)
        }
    }

    private func providerSubtitle(_ providerRow: ProviderSettingsRow) -> String {
        if providerRow.isSignedIn {
            return providerRow.accountLabel ?? "Signed in with your \(providerRow.providerName) plan"
        }
        return providerRow.providerName == "ChatGPT"
            ? "Uses your ChatGPT plan through Codex"
            : "Uses your \(providerRow.providerName) plan through Claude Code"
    }

    @ViewBuilder
    private func providerAccountButton(_ providerRow: ProviderSettingsRow) -> some View {
        let slug = providerRow.identifierSlug
        if providerRow.isSignedIn {
            Button(action: { state.onSignOut(providerRow.providerName) }) {
                Text("Sign out")
            }
            .clickyWindowButton(.quietDestructive, isCompact: true)
            .disabled(providerRow.isBusy)
            .accessibilityIdentifier("settings.signOut.\(slug)")
        } else {
            Button(action: { state.onSignIn(providerRow.providerName) }) {
                Text(providerRow.isBusy ? "Waiting for browser" : "Sign in to \(providerRow.providerName)")
            }
            .clickyWindowButton(.primary, isCompact: true)
            .disabled(providerRow.isBusy)
            .accessibilityIdentifier("settings.signIn.\(slug)")
        }
    }

    /// The measured time is the value, so it gets the weight; its label stays small.
    private func answerTimeLine(_ providerRow: ProviderSettingsRow) -> some View {
        Group {
            if let measuredAnswerSeconds = providerRow.measuredAnswerSeconds {
                (Text(WindowTimeFormatting.seconds(measuredAnswerSeconds))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(DS.Colors.textPrimary)
                 + Text("  typical answer on this Mac")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted))
            } else {
                Text("Measured after your first answer")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: "Session notes",
                caption: "Sessions stay on this Mac. Save to vault writes one into this folder."
            )

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(state.notesFolderPath == nil ? DS.Colors.warning : DS.Colors.textMuted)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notes folder")
                            .font(DS.WindowText.bodyEmphasis)
                            .foregroundColor(DS.Colors.textPrimary)
                        if let notesFolderPath = state.notesFolderPath {
                            Text(abbreviatedPath(notesFolderPath))
                                .font(DS.WindowText.meta)
                                .foregroundColor(DS.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("settings.notesFolderPath")
                            if state.isNotesFolderSetByEnvironment {
                                Text("Set by CLICKY_VAULT_ROOT")
                                    .font(DS.WindowText.meta)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .accessibilityIdentifier("settings.notesFolderOverrideNote")
                            }
                        } else {
                            Text("Not chosen yet. Save to vault needs it.")
                                .font(DS.WindowText.meta)
                                .foregroundColor(DS.Colors.warningText)
                                .accessibilityIdentifier("settings.notesFolderPath")
                        }
                    }
                    Spacer(minLength: 8)
                    Button(action: state.onChooseNotesFolder) {
                        Text(state.notesFolderPath == nil ? "Choose folder" : "Change")
                    }
                    .clickyWindowButton(state.notesFolderPath == nil ? .primary : .secondary, isCompact: true)
                    .accessibilityIdentifier("settings.notesFolder")
                }
                .padding(14)

                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.5)).frame(height: 1).padding(.leading, 44)

                Toggle(isOn: Binding(
                    get: { state.isSummaryAtStopEnabled },
                    set: { isEnabled in state.onToggleSummary(isEnabled) }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textMuted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Summary when I stop")
                                .font(DS.WindowText.bodyEmphasis)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("One short text-only request at Stop. No screenshots are sent.")
                                .font(DS.WindowText.meta)
                                .foregroundColor(DS.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(WindowSwitchToggleStyle())
                .padding(14)
                .accessibilityIdentifier("settings.summaryToggle")
            }
            .background(
                RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
            )
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                title: "Permissions",
                caption: "Nothing is captured outside a session you start."
            )

            VStack(alignment: .leading, spacing: 12) {
                permissionLine(systemImageName: "mic", name: "Microphone", reason: "hears your question between the two key presses")
                permissionLine(systemImageName: "rectangle.dashed.badge.record", name: "Screen Recording", reason: "shows the AI your screen when you ask")
                permissionLine(systemImageName: "hand.raised", name: "Accessibility", reason: "notices the question key and which window is in front")
            }
            .padding(.leading, 2)

            WindowCallout(
                kind: .info,
                title: "Screen Recording asks again about once a month",
                message: "On macOS Sequoia, the system asks you to re-approve screen recording roughly monthly. Choose Allow to keep going. The app can't skip that prompt.",
                messageIdentifier: "settings.permissionsNote"
            )
        }
    }

    private func permissionLine(systemImageName: String, name: String, reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(DS.Colors.textMuted)
                .frame(width: 18)
            (Text(name)
                .font(DS.WindowText.bodyEmphasis)
                .foregroundColor(DS.Colors.textPrimary)
             + Text("  \(reason)")
                .font(DS.WindowText.body)
                .foregroundColor(DS.Colors.textMuted))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func sectionHeading(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DS.WindowText.windowTitle)
                .foregroundColor(DS.Colors.textPrimary)
            Text(caption)
                .font(DS.WindowText.body)
                .foregroundColor(DS.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shows the home folder as "~" so the useful end of the path fits.
    private func abbreviatedPath(_ fullPath: String) -> String {
        (fullPath as NSString).abbreviatingWithTildeInPath
    }
}
