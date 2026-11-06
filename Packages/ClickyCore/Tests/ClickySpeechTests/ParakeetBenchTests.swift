import Foundation
import Testing
@testable import ClickySpeech

/// Prints word accuracy and timing for Parakeet on `say` clips (the numbers go in the slice report).
@Suite struct ParakeetBenchTests {
    @Test func parakeetBenchOnSpokenClips() async throws {
        let parakeet = try await SpeechTestSupport.sharedParakeet.value
        print("BENCH load seconds: \(parakeet.loadSeconds)")
        let cases: [(voice: String, text: String)] = [
            ("Samantha", "where do I click to save this file"),
            ("Alex", "open Xcode and build the project"),
            ("Daniel", "how do I change the volume in System Settings"),
            ("Karen", "which button closes this Safari tab"),
            ("Samantha", "what does this error message mean in the terminal"),
            ("Alex", "scroll down to the bottom of the page and press submit"),
        ]
        var wordsWanted = 0
        var wordsWrong = 0
        for benchCase in cases {
            let samples = try SpeechTestSupport.spokenSamples(benchCase.text, voice: benchCase.voice)
            let started = Date()
            let text = try await parakeet.transcribe(samples: samples, sampleRate: 16_000)
            let seconds = Date().timeIntervalSince(started)
            print("BENCH [\(benchCase.voice)] clip \(Double(samples.count) / 16_000)s took \(seconds)s | want: \(benchCase.text) | got: \(text)")
            let wanted = Self.words(benchCase.text)
            let heard = Set(Self.words(text))
            wordsWanted += wanted.count
            wordsWrong += wanted.filter { !heard.contains($0) }.count
        }
        print("BENCH words wrong: \(wordsWrong) of \(wordsWanted)")
        // Spoken app names and plain sentences: at most one word in ten may be missed.
        #expect(Double(wordsWrong) / Double(wordsWanted) <= 0.10)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
