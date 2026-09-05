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
        first.whisperModel = .small
        first.wordTimestamps = true
        first.autoFollowTranscript = false
        first.locationCaptureEnabled = true

        // A fresh instance reads the persisted values back.
        let second = AppSettings(defaults: defaults)
        #expect(second.whisperModel == .small)
        #expect(second.wordTimestamps == true)
        #expect(second.autoFollowTranscript == false)
        #expect(second.locationCaptureEnabled == true)
    }

    @Test func defaultsAreSaneWhenUnset() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.whisperModel == AppSettings.WhisperModel.platformDefault)
        #expect(settings.wordTimestamps == false)
        #expect(settings.autoFollowTranscript == true)
        // Location tagging is opt-in — off unless the user turns it on.
        #expect(settings.locationCaptureEnabled == false)
    }

    @Test func whisperVariantNamesMatchWhisperKitRepo() {
        #expect(AppSettings.WhisperModel.tiny.whisperKitVariant == "openai_whisper-tiny")
        #expect(AppSettings.WhisperModel.base.whisperKitVariant == "openai_whisper-base")
        #expect(AppSettings.WhisperModel.small.whisperKitVariant == "openai_whisper-small")
        #expect(AppSettings.WhisperModel.largeTurbo.whisperKitVariant == "openai_whisper-large-v3-v20240930_turbo")
        #expect(AppSettings.WhisperModel.largeV3.whisperKitVariant == "openai_whisper-large-v3-v20240930")
    }
}
