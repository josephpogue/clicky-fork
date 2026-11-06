//
//  BrainSearchSettingsSection.swift
//  leanring-buddy
//
//  Two Settings sections for answers that search the user's notes:
//  - "Folders Clicky can search": the folder list with a remove control per row, Add folder, and the index
//    status line. An empty list turns searching off, and the section is then just its caption and Add folder.
//  - "When you say "dig deeper"": the stronger model per provider and the effort for that one question,
//    drawn with the same pills as the provider card's Model row and the Answer by chips.
//  Both read `SettingsState` and only call its closures.
//

import ClickyCore
import SwiftUI

// MARK: - Folders Clicky can search

struct SearchFoldersSettingsSection: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeading(
                title: "Folders Clicky can search",
                caption: "Clicky looks in these folders' notes only when a question needs them. With no folders, it answers from your screen alone."
            )

            if state.searchFolderPaths.isEmpty {
                addFolderButton
            } else {
                folderCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.searchFolders")
    }

    private var folderCard: some View {
        VStack(spacing: 0) {
            ForEach(0..<state.searchFolderPaths.count, id: \.self) { folderIndex in
                if folderIndex > 0 {
                    rowDivider
                }
                folderRow(path: state.searchFolderPaths[folderIndex], folderIndex: folderIndex)
            }

            rowDivider

            HStack(spacing: 12) {
                indexStatusLine
                Spacer(minLength: 8)
                addFolderButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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

    /// Starts after the folder icon, like the dividers in the Session notes card.
    private var rowDivider: some View {
        Rectangle().fill(DS.Colors.borderSubtle.opacity(0.5)).frame(height: 1).padding(.leading, 44)
    }

    private func folderRow(path: String, folderIndex: Int) -> some View {
        let shownPath = (path as NSString).abbreviatingWithTildeInPath
        return HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textMuted)
                .frame(width: 18)
            Text(shownPath)
                .font(DS.WindowText.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                // The useful ends of a long path are its start (where it lives) and its last folder.
                .truncationMode(.middle)
                .help(path)
                .accessibilityIdentifier("settings.searchFolder.\(folderIndex)")
            Spacer(minLength: 8)
            Button(action: { state.onRemoveSearchFolder(path) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
            }
            .buttonStyle(SearchFolderRemoveButtonStyle())
            .help("Stop searching \(shownPath)")
            .accessibilityLabel("Remove \(shownPath)")
            .accessibilityIdentifier("settings.removeSearchFolder.\(folderIndex)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    @ViewBuilder
    private var indexStatusLine: some View {
        if let indexStatus = state.searchFolderIndexStatus {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                switch indexStatus.kind {
                case .ready:
                    EmptyView()
                case .working:
                    WindowSpinner(diameter: 11)
                        .alignmentGuide(.firstTextBaseline) { spinnerDimensions in spinnerDimensions[.bottom] - 1 }
                case .problem:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                }
                Text(indexStatus.text)
                    .font(indexStatus.kind == .ready ? DS.WindowText.metaNumbers : DS.WindowText.meta)
                    .foregroundColor(indexStatus.kind == .problem ? DS.Colors.warningText : DS.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(indexStatus.text)
            .accessibilityIdentifier("settings.searchFolderStatus")
        }
    }

    private var addFolderButton: some View {
        Button(action: state.onAddSearchFolder) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Add folder")
            }
        }
        .clickyWindowButton(.secondary, isCompact: true)
        .accessibilityIdentifier("settings.addSearchFolder")
    }
}

/// The remove control on a folder row: a quiet cross that gets a round fill and brightens on hover, with the
/// pointing hand. 28 points square so it is easy to hit, though the cross itself is small.
private struct SearchFolderRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SearchFolderRemoveButtonBody(configuration: configuration)
    }
}

private struct SearchFolderRemoveButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textMuted)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(configuration.isPressed ? DS.Colors.surface4 : (isHovered ? DS.Colors.surface3 : Color.clear))
            )
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHoveringNow in
                isHovered = isEnabled && isHoveringNow
            }
            .pointerCursor(isEnabled: isEnabled)
    }
}

// MARK: - Dig deeper

struct DigDeeperSettingsSection: View {
    @ObservedObject var state: SettingsState

    /// Wide enough for "ChatGPT" in the meta style, so every row's pills start on one edge.
    private let rowLabelWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeading(
                title: "When you say \u{201C}dig deeper\u{201D}",
                caption: "That one question gets a stronger model and more effort. The next question is back to your usual model."
            )

            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.digDeeperModelRows) { modelRow in
                    modelChoiceRow(modelRow)
                }

                if !state.digDeeperModelRows.isEmpty {
                    Rectangle().fill(DS.Colors.borderSubtle.opacity(0.5)).frame(height: 1)
                }

                HStack(alignment: .top, spacing: 12) {
                    rowLabel("Effort")
                    HStack(spacing: 6) {
                        effortChip(title: "Low", effort: .low)
                        effortChip(title: "Medium", effort: .medium)
                        effortChip(title: "High", effort: .high)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.digDeeper.effort")
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.digDeeper")
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(DS.WindowText.meta)
            .foregroundColor(DS.Colors.textMuted)
            // As tall as a pill, so the label sits level with the first row of pills even when they wrap.
            .frame(width: rowLabelWidth, height: 26, alignment: .leading)
    }

    private func modelChoiceRow(_ modelRow: DigDeeperModelRow) -> some View {
        let slug = modelRow.identifierSlug
        return HStack(alignment: .top, spacing: 12) {
            rowLabel(modelRow.providerName)
            if modelRow.models.isEmpty {
                Text("Sign in to choose")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
                    .frame(height: 26)
            } else {
                WrappingRowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(modelRow.models, id: \.self) { modelName in
                        WindowChoicePill(
                            title: modelName.isEmpty ? "default" : modelName,
                            isSelected: modelName == modelRow.selectedModel,
                            action: { state.onChangeDigDeeperModel(modelRow.providerName, modelName) }
                        )
                        .help(modelName.isEmpty ? "The model the \(modelRow.providerName) CLI picks itself" : modelName)
                        .accessibilityIdentifier("settings.digDeeper.model.\(slug).\(modelName.isEmpty ? "default" : modelName)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.digDeeper.model.\(slug)")
            }
        }
    }

    private func effortChip(title: String, effort: AnswerEffort) -> some View {
        WindowChoicePill(
            title: title,
            isSelected: state.digDeeperEffort == effort,
            action: { state.onChangeDigDeeperEffort(effort) }
        )
        .accessibilityValue(state.digDeeperEffort == effort ? "selected" : "not selected")
        .accessibilityIdentifier("settings.digDeeper.effort.\(effort.rawValue)")
    }
}

// MARK: - Shared heading

/// The title and caption over a Settings section, the same as `SettingsView`'s own headings.
struct SettingsSectionHeading: View {
    let title: String
    let caption: String

    var body: some View {
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
}
