import Foundation

/// Decides whether a question is about an earlier moment, and which saved view that is.
public enum EarlierMomentPicker {
    private static let minimumAgeSeconds: TimeInterval = 20

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    public static func pick(
        question: String,
        groups: [ShotGroup],
        now: Date,
        currentAppName: String,
        currentWindowTitle: String?
    ) -> ShotGroup? {
        let eligible = groups.filter { now.timeIntervalSince($0.capturedAt) >= minimumAgeSeconds }
        guard !eligible.isEmpty else { return nil }
        let lowered = question.lowercased()

        // 1. A relative time
        if let secondsAgo = relativeSeconds(in: lowered) {
            let target = now.addingTimeInterval(-secondsAgo)
            return eligible.min { first, second in
                let firstGap = abs(first.capturedAt.timeIntervalSince(target))
                let secondGap = abs(second.capturedAt.timeIntervalSince(target))
                if firstGap != secondGap { return firstGap < secondGap }
                return first.capturedAt > second.capturedAt
            }
        }

        guard hasBackReference(lowered) else { return nil }

        // 2. A word that names an app or window seen earlier
        let questionWords = Set(letterWords(in: lowered).filter { $0.count >= 4 })
        let named = eligible.filter { group in
            let groupWords = Set(letterWords(in: (group.appName + " " + (group.windowTitle ?? "")).lowercased()))
            return !questionWords.isDisjoint(with: groupWords)
        }
        if let latest = named.max(by: { $0.capturedAt < $1.capturedAt }) { return latest }

        // 3. The latest view that differs from what is on screen now
        let currentTitle = currentWindowTitle ?? ""
        return eligible
            .filter { $0.appName != currentAppName || ($0.windowTitle ?? "") != currentTitle }
            .max { $0.capturedAt < $1.capturedAt }
    }

    private static func relativeSeconds(in lowered: String) -> Double? {
        if lowered.range(of: #"\bhalf an hour ago\b"#, options: .regularExpression) != nil {
            return 1800
        }
        let pattern = #"\b(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten)\s+(second|minute|hour)s?\s+ago\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let amountRange = Range(match.range(at: 1), in: lowered),
              let unitRange = Range(match.range(at: 2), in: lowered) else { return nil }

        let amountText = String(lowered[amountRange])
        guard let amount = Double(amountText) ?? numberWords[amountText] else { return nil }
        switch lowered[unitRange] {
        case "second": return amount
        case "minute": return amount * 60
        default: return amount * 3600
        }
    }

    private static func hasBackReference(_ lowered: String) -> Bool {
        lowered.range(
            of: #"\b(earlier|before|previous|previously|ago|back|last time|was|had|saw)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func letterWords(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }
}
