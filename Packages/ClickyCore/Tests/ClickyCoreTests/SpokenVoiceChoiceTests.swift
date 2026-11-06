import Foundation
import Testing
@testable import ClickyCore

/// Which Mac voices Settings lists for spoken answers, how they are named, and which one reads.
struct SpokenVoiceChoiceTests {
    private let sampleVoices: [SpokenVoiceCandidate] = [
        SpokenVoiceCandidate(identifier: "a", name: "Samantha", languageCode: "en-US", quality: .standard, isNovelty: false),
        SpokenVoiceCandidate(identifier: "b", name: "Zoe", languageCode: "en-US", quality: .premium, isNovelty: false),
        SpokenVoiceCandidate(identifier: "c", name: "Ava", languageCode: "en-US", quality: .enhanced, isNovelty: false),
        SpokenVoiceCandidate(identifier: "d", name: "Daniel", languageCode: "en-GB", quality: .enhanced, isNovelty: false),
        SpokenVoiceCandidate(identifier: "e", name: "Thomas", languageCode: "fr-FR", quality: .standard, isNovelty: false),
        SpokenVoiceCandidate(identifier: "f", name: "Bells", languageCode: "en-US", quality: .standard, isNovelty: true),
    ]

    @Test func listsUserLanguageVoicesBestQualityFirstWithoutNovelty() {
        let listed = SpokenVoiceChoice.listedVoices(from: sampleVoices, userLanguageCode: "en-US")
        #expect(listed.map(\.displayName) == ["Zoe (Premium)", "Ava (Enhanced)", "Daniel (Enhanced)", "Samantha"])
        #expect(listed.map(\.identifier) == ["b", "c", "d", "a"])
    }

    @Test func exactLanguageBeatsOtherRegionsThenNameDecides() {
        let voices = [
            SpokenVoiceCandidate(identifier: "1", name: "Zed", languageCode: "en-US", quality: .standard, isNovelty: false),
            SpokenVoiceCandidate(identifier: "2", name: "Amy", languageCode: "en-GB", quality: .standard, isNovelty: false),
            SpokenVoiceCandidate(identifier: "3", name: "Ben", languageCode: "en-US", quality: .standard, isNovelty: false),
        ]
        let listed = SpokenVoiceChoice.listedVoices(from: voices, userLanguageCode: "en-US")
        #expect(listed.map(\.identifier) == ["3", "1", "2"])
    }

    @Test func languageMatchIgnoresSeparatorStyle() {
        let voices = [SpokenVoiceCandidate(identifier: "g", name: "Karen", languageCode: "en_AU", quality: .standard, isNovelty: false)]
        #expect(SpokenVoiceChoice.listedVoices(from: voices, userLanguageCode: "en-US").count == 1)
    }

    @Test func suffixIsNotDoubled() {
        let voices = [
            SpokenVoiceCandidate(identifier: "p", name: "Zoe (Premium)", languageCode: "en-US", quality: .premium, isNovelty: false),
            SpokenVoiceCandidate(identifier: "q", name: "Ava (Enhanced)", languageCode: "en-US", quality: .enhanced, isNovelty: false),
        ]
        let listed = SpokenVoiceChoice.listedVoices(from: voices, userLanguageCode: "en-US")
        #expect(listed.map(\.displayName) == ["Zoe (Premium)", "Ava (Enhanced)"])
    }

    @Test func chosenVoiceIsSavedOneWhenListedElseFirst() {
        let listed = SpokenVoiceChoice.listedVoices(from: sampleVoices, userLanguageCode: "en-US")
        #expect(SpokenVoiceChoice.chosenVoice(savedIdentifier: "e", listedVoices: listed)?.identifier == "b")
        #expect(SpokenVoiceChoice.chosenVoice(savedIdentifier: "c", listedVoices: listed)?.identifier == "c")
        #expect(SpokenVoiceChoice.chosenVoice(savedIdentifier: nil, listedVoices: listed)?.identifier == "b")
    }

    @Test func noListedVoicesChoosesNothing() {
        #expect(SpokenVoiceChoice.chosenVoice(savedIdentifier: "b", listedVoices: []) == nil)
        #expect(SpokenVoiceChoice.listedVoices(from: [], userLanguageCode: "en-US").isEmpty)
    }
}
