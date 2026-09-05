// The new intents' (OpenInspectorIntent/TranscribeLinkIntent/RenameTranscriptIntent/
// PlaybackIntents) `perform()` bodies are genuinely untestable in a plain `swift test`
// process: each depends on the live `AppModel` via `@Dependency`, and AppIntents' dependency
// resolution is gated on running inside the system's own intent-perform dispatch — confirmed
// empirically (`AppDependencyManager.shared.add(dependency:)` registered up front, then
// calling `.perform()` directly still traps: "Dependency values can only be accessed inside of
// the intent perform flow… unless the value of the dependency is manually set prior to
// access" — and the `@Dependency`-wrapped property is `private`, so a test can't reach in and
// set it either). That crash is deterministic, not an environment fluke, so parameter
// validation, the Mac-only guard, and title-trimming — all inline in each `perform()` — can't
// be exercised without a Sources change to make the dependency injectable, which is out of
// scope here.
//
// What IS pure and reachable without `@Dependency` is each intent's error type — the exact
// messages Siri/Shortcuts surfaces on the failure paths above.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("Intent error messages — pure, no @Dependency needed")
struct IntentErrorMessagesTests {
    @Test func transcribeLinkErrorsHaveDistinctNonEmptyMessages() {
        let unavailable = String(localized: TranscribeLinkIntentError.unavailableOnThisDevice.localizedStringResource)
        let invalid = String(localized: TranscribeLinkIntentError.invalidLink.localizedStringResource)
        #expect(!unavailable.isEmpty)
        #expect(!invalid.isEmpty)
        #expect(unavailable != invalid)
    }

    @Test func renameErrorsHaveDistinctNonEmptyMessages() {
        let notFound = String(localized: RenameTranscriptIntentError.transcriptNotFound.localizedStringResource)
        let empty = String(localized: RenameTranscriptIntentError.emptyTitle.localizedStringResource)
        #expect(!notFound.isEmpty)
        #expect(!empty.isEmpty)
        #expect(notFound != empty)
    }

    @Test func playbackErrorsHaveDistinctNonEmptyMessages() {
        let messages = [PlaybackIntentError.noAudioAvailable, .notPlaying, .nothingToSpeak, .notSpeaking]
            .map { String(localized: $0.localizedStringResource) }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
    }
}

@Suite("StoredModel — display detail (Settings/Storage)")
struct StoredModelDetailTests {
    // The one StoredModel branch ModelStorageScannerTests doesn't already cover: the
    // kind-specific subtitle shown under each row in the Storage section.
    @Test func detailDistinguishesRecognitionFromDiarizationFromSynthesis() {
        let recognizer = StoredModel(kind: .speech(.parakeet), paths: [], bytes: 0)
        let diarizer = StoredModel(kind: .speech(.sortformer), paths: [], bytes: 0)
        let synthesis = StoredModel(kind: .speechSynthesis, paths: [], bytes: 0)
        #expect(recognizer.detail.hasPrefix("Speech recognition"))
        #expect(diarizer.detail.hasPrefix("Speaker diarization"))
        #expect(synthesis.detail == "Speech synthesis")
    }
}
