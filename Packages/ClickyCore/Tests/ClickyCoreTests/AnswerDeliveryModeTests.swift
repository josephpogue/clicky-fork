import Foundation
import Testing
@testable import ClickyCore

/// Settings stores the mode by its raw value, and the session decides text and speech from it.
struct AnswerDeliveryModeTests {
    @Test func eachModeShowsTextOrSpeaksAsSettingsDescribes() {
        #expect(AnswerDeliveryMode.text.showsText == true)
        #expect(AnswerDeliveryMode.text.speaksAloud == false)
        #expect(AnswerDeliveryMode.spoken.showsText == false)
        #expect(AnswerDeliveryMode.spoken.speaksAloud == true)
        #expect(AnswerDeliveryMode.both.showsText == true)
        #expect(AnswerDeliveryMode.both.speaksAloud == true)
    }

    @Test func rawValuesStayStableForSavedSettings() {
        #expect(AnswerDeliveryMode(rawValue: "text") == .text)
        #expect(AnswerDeliveryMode(rawValue: "spoken") == .spoken)
        #expect(AnswerDeliveryMode(rawValue: "both") == .both)
        #expect(AnswerDeliveryMode.allCases.count == 3)
    }
}
