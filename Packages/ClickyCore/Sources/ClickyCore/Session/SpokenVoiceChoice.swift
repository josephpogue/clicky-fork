import Foundation

/// How good a Mac voice sounds, from the voices macOS ships (standard) to the ones the user downloaded.
public enum SpokenVoiceQuality: Int, Sendable, Equatable {
    case standard = 0
    case enhanced = 1
    case premium = 2
}

/// One voice the Mac offers, in plain values so the choosing rules can be tested without AVFoundation.
public struct SpokenVoiceCandidate: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let languageCode: String
    public let quality: SpokenVoiceQuality
    public let isNovelty: Bool

    public init(identifier: String, name: String, languageCode: String, quality: SpokenVoiceQuality, isNovelty: Bool) {
        self.identifier = identifier
        self.name = name
        self.languageCode = languageCode
        self.quality = quality
        self.isNovelty = isNovelty
    }
}

/// A voice Settings lists, with the name the user sees.
public struct ListedSpokenVoice: Sendable, Equatable {
    public let identifier: String
    public let displayName: String
}

/// Which voices Settings lists for spoken answers and which one reads. A voice of another language reads
/// English answers badly, and novelty voices (Bells, Zarvox) are jokes, so neither is listed.
public enum SpokenVoiceChoice {
    /// The user's language as "<language>-<region>" ("en-US"), or just the language with no region. Built from
    /// the locale's parts, because its identifier can carry modifiers ("en_US@rg=gbzzzz").
    public static func userLanguageCode(for locale: Locale) -> String {
        guard let language = locale.language.languageCode?.identifier else {
            return locale.identifier.replacingOccurrences(of: "_", with: "-")
        }
        guard let region = locale.language.region?.identifier else { return language }
        return "\(language)-\(region)"
    }

    public static func listedVoices(from candidates: [SpokenVoiceCandidate], userLanguageCode: String) -> [ListedSpokenVoice] {
        let userLanguage = normalizedLanguage(userLanguageCode)
        let userLanguagePrefix = languagePrefix(of: userLanguage)

        let matchingCandidates = candidates.filter { candidate in
            !candidate.isNovelty && languagePrefix(of: normalizedLanguage(candidate.languageCode)) == userLanguagePrefix
        }

        let orderedCandidates = matchingCandidates.sorted { first, second in
            if first.quality != second.quality {
                return first.quality.rawValue > second.quality.rawValue
            }
            let firstIsExactLanguage = normalizedLanguage(first.languageCode) == userLanguage
            let secondIsExactLanguage = normalizedLanguage(second.languageCode) == userLanguage
            if firstIsExactLanguage != secondIsExactLanguage {
                return firstIsExactLanguage
            }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }

        return orderedCandidates.map { candidate in
            ListedSpokenVoice(identifier: candidate.identifier, displayName: displayName(for: candidate))
        }
    }

    /// The saved voice when it is listed, otherwise the first listed voice, otherwise nil (the player then
    /// asks macOS for its default voice).
    public static func chosenVoice(savedIdentifier: String?, listedVoices: [ListedSpokenVoice]) -> ListedSpokenVoice? {
        if let savedIdentifier, let savedVoice = listedVoices.first(where: { $0.identifier == savedIdentifier }) {
            return savedVoice
        }
        return listedVoices.first
    }

    private static func displayName(for candidate: SpokenVoiceCandidate) -> String {
        let suffix: String
        switch candidate.quality {
        case .standard: return candidate.name
        case .enhanced: suffix = " (Enhanced)"
        case .premium: suffix = " (Premium)"
        }
        return candidate.name.hasSuffix(suffix) ? candidate.name : candidate.name + suffix
    }

    /// "en_AU" and "en-AU" are the same language; AVFoundation uses the dash.
    private static func normalizedLanguage(_ languageCode: String) -> String {
        languageCode.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languagePrefix(of normalizedLanguage: String) -> String {
        normalizedLanguage.split(separator: "-").first.map(String.init) ?? normalizedLanguage
    }
}
