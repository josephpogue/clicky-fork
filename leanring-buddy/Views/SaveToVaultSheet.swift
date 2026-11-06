//
//  SaveToVaultSheet.swift
//  leanring-buddy
//
//  The Save to vault sheet. The suggested project is selected when it opens,
//  so one press of Save files the session; every other project and "No
//  project" sit right below it. The Save button names where it will save.
//

import SwiftUI

struct SaveToVaultSheet: View {
    @ObservedObject var state: SaveToVaultState
    /// Called with the chosen project, or nil for "No project".
    let onConfirm: (_ selectedProject: String?) -> Void
    /// Closes the sheet. Also used by Done after a save.
    let onCancel: () -> Void
    /// Added for the design: lets the "no notes folder" state send the user
    /// straight to Settings. The button only shows when this is set.
    var onOpenSettings: (() -> Void)? = nil

    private let sheetWidth: CGFloat = 420

    var body: some View {
        Group {
            switch state.phase {
            case .saved(let notePath, let committed, let commitError):
                savedResult(notePath: notePath, committed: committed, commitError: commitError)
            case .choosing, .saving, .failed:
                chooser
            }
        }
        .frame(width: sheetWidth)
        .background(DS.Colors.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("save.sheet")
    }

    private var isSaving: Bool { state.phase == .saving }

    // MARK: - Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save to vault")
                    .font(DS.WindowText.windowTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Writes the log and the screens tied to your questions to your notes folder, and links it from the project page.")
                    .font(DS.WindowText.body)
                    .lineSpacing(DS.WindowText.bodyLineSpacing)
                    .foregroundColor(DS.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            if state.notesFolderMissing {
                WindowCallout(
                    kind: .warning,
                    title: "No notes folder yet",
                    message: "Choose one in Settings first. Save writes the session there.",
                    messageIdentifier: "save.result"
                ) {
                    if let onOpenSettings {
                        Button(action: onOpenSettings) {
                            Text("Open Settings")
                        }
                        .clickyWindowButton(.secondary, isCompact: true)
                        .accessibilityIdentifier("save.openSettings")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            projectList
                .padding(.horizontal, 16)
                .disabled(isSaving || state.notesFolderMissing)
                .opacity(state.notesFolderMissing ? 0.5 : 1)

            if case .failed(let message) = state.phase {
                WindowCallout(kind: .error, title: "Couldn't save", message: message, messageIdentifier: "save.result")
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }

            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 1)
                .padding(.top, 16)

            HStack(spacing: 8) {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                }
                .clickyWindowButton(.quiet)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .accessibilityIdentifier("save.cancel")

                Button(action: { onConfirm(state.selectedProject) }) {
                    HStack(spacing: 7) {
                        if isSaving {
                            WindowSpinner(diameter: 12, tint: DS.Colors.textOnAccent)
                        }
                        Text(confirmButtonTitle)
                    }
                }
                .clickyWindowButton(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || state.notesFolderMissing)
                .accessibilityIdentifier("save.confirm")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(DS.Colors.surface1)
        }
    }

    private var confirmButtonTitle: String {
        if isSaving { return "Saving" }
        if case .failed = state.phase { return "Try again" }
        if let selectedProject = state.selectedProject { return "Save to \(selectedProject)" }
        return "Save without a project"
    }

    /// The suggestion and "No project" first, the two likeliest picks, then
    /// every other project A to Z.
    private var orderedOtherProjects: [String] {
        state.projects
            .filter { $0 != state.suggestedProject }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var projectList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                if let suggestedProject = state.suggestedProject {
                    projectChoiceRow(title: suggestedProject, project: suggestedProject, isSuggested: true)
                }
                projectChoiceRow(title: "No project", project: nil, isSuggested: false)
                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.5)).frame(height: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                ForEach(orderedOtherProjects, id: \.self) { projectName in
                    projectChoiceRow(title: projectName, project: projectName, isSuggested: false)
                }
            }
            .padding(4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 236)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("save.project")
    }

    private func projectChoiceRow(title: String, project: String?, isSuggested: Bool) -> some View {
        let isSelected = state.selectedProject == project
        return Button(action: { state.selectedProject = project }) {
            HStack(spacing: 10) {
                // The radio sits left of its label so the eye meets the control first.
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: isSelected ? 5 : 1.5)
                        .background(Circle().fill(isSelected ? Color.white : Color.clear).padding(4))
                }
                .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(project == nil ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if isSuggested {
                    WindowStatusChip(text: "Suggested", tint: DS.Colors.accentText, systemImageName: "sparkles")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ClickyRowButtonStyle(
            cornerRadius: 7,
            restingFill: isSelected ? DS.Colors.accentSubtle : Color.clear,
            hoverFill: isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(project.map { "save.project.\($0)" } ?? "save.project.none")
    }

    // MARK: - Saved

    private func savedResult(notePath: String, committed: Bool, commitError: String?) -> some View {
        let isClean = committed && commitError == nil
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(isClean ? DS.Colors.success : DS.Colors.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(savedTitle(isClean: isClean))
                            .font(DS.WindowText.windowTitle)
                            .foregroundColor(DS.Colors.textPrimary)
                            .accessibilityIdentifier("save.result")
                        Text(isClean ? "Committed to the vault." : "The note is written but not committed.")
                            .font(DS.WindowText.body)
                            .foregroundColor(DS.Colors.textMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note")
                        .font(DS.WindowText.meta)
                        .foregroundColor(DS.Colors.textMuted)
                    Text((notePath as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("save.notePath")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                        .fill(DS.Colors.surface1)
                )

                if let commitError {
                    WindowCallout(
                        kind: .warning,
                        title: "Git commit failed",
                        message: "\(commitError) The files are in place; commit them from the vault when you can.",
                        messageIdentifier: "save.commitError"
                    )
                }
            }
            .padding(24)

            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 1)

            HStack {
                Spacer()
                Button(action: onCancel) {
                    Text("Done")
                }
                .clickyWindowButton(.primary)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("save.done")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(DS.Colors.surface1)
        }
    }

    private func savedTitle(isClean: Bool) -> String {
        let destination = state.selectedProject.map { "Saved to \($0)" } ?? "Saved"
        return isClean ? destination : "\(destination), not committed"
    }
}
