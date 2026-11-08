import Foundation

/// Turns a session's events into the markdown timeline kept in `log.md` and saved to the vault.
public enum SessionLogRenderer {
    /// `shotLink` gives the link target for a shot, or nil to leave that image out.
    /// Shots whose group is not in `shotGroups` (cleanup deleted it) are left out.
    public static func render(
        metadata: SessionMetadata,
        events: [SessionEvent],
        shotGroups: [ShotGroup],
        timeZone: TimeZone,
        shotLink: (DisplayShot) -> String?
    ) -> String {
        let clockFormatter = SessionLogText.timeFormatter(pattern: "HH:mm:ss", timeZone: timeZone)
        let minuteFormatter = SessionLogText.timeFormatter(pattern: "HH:mm", timeZone: timeZone)
        let dayFormatter = SessionLogText.timeFormatter(pattern: "yyyy-MM-dd", timeZone: timeZone)

        var lines: [String] = []

        var title = "# Session \(dayFormatter.string(from: metadata.startedAt)) \(minuteFormatter.string(from: metadata.startedAt))"
        if let endedAt = metadata.endedAt {
            title += " to \(minuteFormatter.string(from: endedAt))"
        }
        lines.append(title)
        lines.append("")

        if let summary = metadata.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("**Summary:** \(SessionLogText.singleLine(summary))")
            lines.append("")
        }

        lines.append(statsLine(metadata: metadata, events: events, clockFormatter: clockFormatter))
        lines.append("")
        lines.append("## Timeline")
        lines.append("")

        let groupsByID = Dictionary(shotGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func imageMarkdown(forGroupID groupID: Int) -> [String] {
            guard let group = groupsByID[groupID] else { return [] }
            return group.shots.compactMap { shot in
                shotLink(shot).map { "![screen \(shot.screenNumber)](\($0))" }
            }
        }

        // Screenshots a question line shows itself, so they get no line of their own.
        var questionShotGroupIDs = Set<Int>()
        for event in events {
            if case .question(_, let shotGroupID, _) = event.kind { questionShotGroupIDs.insert(shotGroupID) }
        }

        // A screenshot taken for a switch sits on the focus line right before (or right after) it.
        var imagesForFocusEventAtIndex: [Int: [String]] = [:]
        var screenshotIndexesOnFocusLines = Set<Int>()
        for (index, event) in events.enumerated() {
            guard case .screenshot(let shotGroupID) = event.kind,
                  let group = groupsByID[shotGroupID],
                  [.appSwitch, .windowSwitch, .sessionStart].contains(group.reason) else { continue }
            let neighbourIndexes = [index - 1, index + 1].filter { events.indices.contains($0) }
            guard let focusIndex = neighbourIndexes.first(where: {
                if case .focusChanged = events[$0].kind { return true } else { return false }
            }) else { continue }
            imagesForFocusEventAtIndex[focusIndex, default: []] += imageMarkdown(forGroupID: shotGroupID)
            screenshotIndexesOnFocusLines.insert(index)
        }

        for (index, event) in events.enumerated() {
            let clock = clockFormatter.string(from: event.time)
            switch event.kind {
            case .sessionStarted:
                lines.append("- \(clock) Session started.")
            case .sessionStopped:
                lines.append("- \(clock) Session stopped.")
            case .questionStarted:
                break
            case .focusChanged(let appName, let windowTitle):
                var text = "\(appName)"
                if let windowTitle, !windowTitle.isEmpty { text += ", \"\(SessionLogText.singleLine(windowTitle))\"" }
                text += "."
                lines.append(entry(clock, text, images: imagesForFocusEventAtIndex[index] ?? []))
            case .utterance(let spokenText):
                lines.append("- \(clock) Said: \"\(SessionLogText.singleLine(spokenText))\"")
            case .question(let questionText, let shotGroupID, _):
                lines.append(entry(
                    clock, "**Question:** \"\(SessionLogText.singleLine(questionText))\"",
                    images: imageMarkdown(forGroupID: shotGroupID)
                ))
            case .answer(let answerText, let provider, let model, let secondsToAnswer, let pointLabel):
                var parts: [String] = []
                let plainAnswer = SessionLogText.singleLine(
                    AnswerChatMarker.removing(
                        from: SessionLogText.removingPointTags(from: StreamingAnswerText.removingTrailingIncompleteTag(from: answerText)),
                        joinedBy: " "))
                if !plainAnswer.isEmpty { parts.append(plainAnswer) }
                if let pointLabel, !pointLabel.isEmpty { parts.append("Pointed at: \(pointLabel).") }
                let seconds = String(format: "%.1f", secondsToAnswer)
                lines.append("- \(clock) **Answer** (\(SessionLogText.providerDisplayName(provider)), \(model), \(seconds) s): \(parts.joined(separator: " "))")
            case .answerFailed(let message, let provider, let model, _):
                let plainMessage = SessionLogText.singleLine(message)
                let ending = plainMessage.last.map { ".!?".contains($0) } == true ? "" : "."
                lines.append("- \(clock) Answer failed (\(SessionLogText.providerDisplayName(provider)), \(model)): \(plainMessage)\(ending)")
            case .providerSwitched(let from, let to):
                lines.append("- \(clock) Switched from \(SessionLogText.providerDisplayName(from)) to \(SessionLogText.providerDisplayName(to)).")
            case .screenshot(let shotGroupID):
                if screenshotIndexesOnFocusLines.contains(index) || questionShotGroupIDs.contains(shotGroupID) { break }
                let images = imageMarkdown(forGroupID: shotGroupID)
                if !images.isEmpty { lines.append(entry(clock, "Screen changed.", images: images)) }
            case .digDeeperAsked(let model, let effort):
                let effortPart = effort.map { ", \(SessionLogText.singleLine($0)) effort" } ?? ""
                lines.append("- \(clock) Dig deeper on \(SessionLogText.singleLine(model))\(effortPart).")
            case .passagesAttached(let paths):
                if !paths.isEmpty {
                    lines.append("- \(clock) Notes attached: \(paths.map { SessionLogText.singleLine($0) }.joined(separator: ", ")).")
                }
            case .brainToolCalled(let tool, let argument):
                let plainArgument = SessionLogText.singleLine(argument)
                if tool == BrainToolName.searchBrain.rawValue {
                    lines.append("- \(clock) Searched notes: \"\(plainArgument)\".")
                } else if tool == BrainToolName.readBrainFile.rawValue {
                    lines.append("- \(clock) Read note: \(plainArgument).")
                }
            case .answerTiming(_, _, let wasCutShort):
                // Timing numbers are not for the reader; only a cut-short answer is worth a line.
                if wasCutShort { lines.append("- \(clock) Answer cut short.") }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func entry(_ clock: String, _ text: String, images: [String]) -> String {
        ([ "- \(clock) \(text)" ] + images).joined(separator: " ")
    }

    private static func statsLine(
        metadata: SessionMetadata,
        events: [SessionEvent],
        clockFormatter: DateFormatter
    ) -> String {
        var sentences = ["Started \(clockFormatter.string(from: metadata.startedAt))."]
        if let endedAt = metadata.endedAt {
            sentences.append("Ended \(clockFormatter.string(from: endedAt)).")
        }

        let questionCount = events.filter { if case .question = $0.kind { return true } else { return false } }.count
        sentences.append("\(questionCount) \(questionCount == 1 ? "question" : "questions").")

        var modelNamesInFirstUseOrder: [String] = []
        for event in events {
            guard case .answer(_, let provider, let model, _, _) = event.kind else { continue }
            let name = "\(SessionLogText.providerDisplayName(provider)) \(model)"
            if !modelNamesInFirstUseOrder.contains(name) { modelNamesInFirstUseOrder.append(name) }
        }
        if !modelNamesInFirstUseOrder.isEmpty {
            sentences.append("Models: \(modelNamesInFirstUseOrder.joined(separator: ", ")).")
        }
        return sentences.joined(separator: " ")
    }
}
