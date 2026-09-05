import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("AppSettings — persistence + model mapping")
@MainActor
struct AppSettingsTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func changesPersistAcrossInstances() {
        let defaults = makeDefaults()

        let first = AppSettings(defaults: defaults)
        first.dictationEngine = .studio
        first.wordTimestamps = true
        first.autoFollowTranscript = false
        first.locationCaptureEnabled = true

        // A fresh instance reads the persisted values back.
        let second = AppSettings(defaults: defaults)
        #expect(second.dictationEngine == .studio)
        #expect(second.wordTimestamps == true)
        #expect(second.autoFollowTranscript == false)
        #expect(second.locationCaptureEnabled == true)
    }

    @Test func defaultsAreSaneWhenUnset() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.dictationEngine == .appleSpeech)
        #expect(settings.wordTimestamps == false)
        #expect(settings.autoFollowTranscript == true)
        // Location tagging is opt-in — off unless the user turns it on.
        #expect(settings.locationCaptureEnabled == false)
    }

}
