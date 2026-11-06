import Foundation

/// Builds what one question sends: the current view of every display, then any earlier view, each labelled.
public enum QuestionTurnBuilder {
    public static func turn(
        questionText: String,
        currentGroup: ShotGroup,
        earlierGroup: ShotGroup?,
        shotsDirectory: URL,
        contextNote: String,
        timeZone: TimeZone
    ) -> QuestionTurn {
        let currentShots = currentGroup.shots.sorted { $0.screenNumber < $1.screenNumber }
        var images = currentShots.map { shot in
            TurnImage(
                fileURL: shotsDirectory.appendingPathComponent(shot.fileName),
                label: currentLabel(for: shot, displayCount: currentShots.count),
                pixelWidth: shot.pixelWidth,
                pixelHeight: shot.pixelHeight
            )
        }

        if let earlierGroup {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            let clock = formatter.string(from: earlierGroup.capturedAt)
            var place = earlierGroup.appName
            if let title = earlierGroup.windowTitle, !title.isEmpty { place += " (\(title))" }

            for shot in earlierGroup.shots.sorted(by: { $0.screenNumber < $1.screenNumber }) {
                images.append(TurnImage(
                    fileURL: shotsDirectory.appendingPathComponent(shot.fileName),
                    label: "earlier view from \(clock) in \(place), screen\(shot.screenNumber), "
                        + "image \(shot.pixelWidth)x\(shot.pixelHeight) pixels, for context only, do not point at it",
                    pixelWidth: shot.pixelWidth,
                    pixelHeight: shot.pixelHeight
                ))
            }
        }

        return QuestionTurn(questionText: questionText, contextNote: contextNote, images: images)
    }

    private static func currentLabel(for shot: DisplayShot, displayCount: Int) -> String {
        let size = "image \(shot.pixelWidth)x\(shot.pixelHeight) pixels"
        if displayCount == 1 {
            return "screen\(shot.screenNumber), the user's screen (cursor is here), \(size)"
        }
        let position = "screen\(shot.screenNumber) of \(displayCount)"
        return shot.isCursorScreen
            ? "\(position), cursor is on this screen (primary focus), \(size)"
            : "\(position), secondary screen, \(size)"
    }
}
