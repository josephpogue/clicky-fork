import Foundation

/// A question that starts with the spoken words "dig deeper".
public struct DigDeeperMatch: Equatable, Sendable {
    /// What was said after the phrase, without a leading "on" or "into"; empty when nothing followed
    public var remainingWords: String
}

/// Recognises "dig deeper" at the start of a transcript, including common speech-to-text slips.
/// Only spoken words switch it on; nothing escalates by itself.
public enum DigDeeperMatcher {
    private static let fillerPattern = #"(?:okay|ok|so|please|now|can you|could you)"#
    private static let phrasePattern =
        #"(?:dig a little deeper|dig a bit deeper|dig in deeper|dig[- ]?deeper|dig deep|big deeper|dig dipper|dick deeper|dug deeper|digg deeper)"#

    // Leading punctuation and space, up to six fillers (each may repeat harmlessly), then the phrase and a word boundary.
    private static let pattern =
        "^[\\s\\p{P}]*(?:" + fillerPattern + #"\b[\s,]*)*"# + phrasePattern + #"\b"#

    public static func match(_ transcript: String) -> DigDeeperMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(found.range, in: transcript) else { return nil }

        var rest = String(transcript[range.upperBound...])
        let strippable = CharacterSet(charactersIn: ",.:;-").union(.whitespacesAndNewlines)
        rest = String(rest.unicodeScalars.drop(while: { strippable.contains($0) }))
        for lead in ["into", "on"] {
            if rest.lowercased().hasPrefix(lead + " ") || rest.lowercased() == lead {
                rest = String(rest.dropFirst(lead.count))
                break
            }
        }
        return DigDeeperMatch(remainingWords: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
