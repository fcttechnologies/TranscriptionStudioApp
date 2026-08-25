import Foundation
import Observation

/// User-facing model choices, surfaced in the Settings scene, persisted to `UserDefaults`.
/// The chosen speech model + diarizer backend drive every transcription job (the engines
/// are pulled from `AppModel`'s model-keyed cache); recording keeps its launch-time engines
/// (a model change there takes effect at next launch).
@MainActor
@Observable
final class AppSettings {
    enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
        case tiny, base, small, largeTurbo, largeV3
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .tiny: "Whisper Tiny"
            case .base: "Whisper Base"
            case .small: "Whisper Small"
            case .largeTurbo: "Whisper Large v3 Turbo"
            case .largeV3: "Whisper Large v3"
            }
        }
        var detail: String {
            switch self {
            case .tiny: "Fastest · lowest accuracy"
            case .base: "Fast · light"
            case .small: "Balanced"
            case .largeTurbo: "Recommended · fast + accurate"
            case .largeV3: "Most accurate · heaviest"
            }
        }
        /// The WhisperKit repo variant this maps to (what `WhisperKit.download(variant:)`
        /// resolves against the `argmaxinc/whisperkit-coreml` model repo).
        var whisperKitVariant: String {
            switch self {
            case .tiny: "openai_whisper-tiny"
            case .base: "openai_whisper-base"
            case .small: "openai_whisper-small"
            case .largeTurbo: "openai_whisper-large-v3-v20240930_turbo"
            case .largeV3: "openai_whisper-large-v3-v20240930"
            }
        }

        /// large-v3-turbo is the only model the app uses (the Settings picker was removed — it's
        /// the speed/accuracy sweet spot, verified great on iPhone). The other cases remain solely
        /// so the Storage section can recognize + clean a previously-downloaded variant.
        static var platformDefault: WhisperModel { .largeTurbo }
    }

    enum DiarizerBackend: String, CaseIterable, Identifiable, Sendable {
        case sortformer, speakerKit
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .sortformer: "Streaming Sortformer"
            case .speakerKit: "SpeakerKit (cross-check)"
            }
        }
        var detail: String {
            switch self {
            case .sortformer: "On-device · up to 4 speakers · Core AI"
            case .speakerKit: "Argmax baseline · comparison"
            }
        }
        /// Sortformer only runs where a re-exported model is staged (a Mac); iOS can never
        /// provision it, so iOS defaults to SpeakerKit. macOS defaults to Sortformer.
        static var platformDefault: DiarizerBackend {
            #if os(macOS)
            .sortformer
            #else
            .speakerKit
            #endif
        }
    }

    private enum Keys {
        static let whisperModel = "settings.whisperModel"
        static let diarizerBackend = "settings.diarizerBackend"
        static let wordTimestamps = "settings.wordTimestamps"
        static let autoFollowTranscript = "settings.autoFollowTranscript"
        static let showConfidence = "settings.showConfidence"
        static let locationCaptureEnabled = "settings.locationCaptureEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.rawValue, forKey: Keys.whisperModel) }
    }
    var diarizerBackend: DiarizerBackend {
        didSet { defaults.set(diarizerBackend.rawValue, forKey: Keys.diarizerBackend) }
    }
    /// Capture word-level timestamps (costs decode time) — off by default.
    var wordTimestamps: Bool {
        didSet { defaults.set(wordTimestamps, forKey: Keys.wordTimestamps) }
    }
    /// Auto-follow the live transcript as it grows (yields to manual scroll).
    var autoFollowTranscript: Bool {
        didSet { defaults.set(autoFollowTranscript, forKey: Keys.autoFollowTranscript) }
    }
    /// Verbatim/confidence display: flag low-confidence words in a saved transcript — off by
    /// default so the reading view stays clean; a verifier turns it on per the detail view.
    var showConfidence: Bool {
        didSet { defaults.set(showConfidence, forKey: Keys.showConfidence) }
    }
    /// Tag a live recording with the coarse place it was made (reverse-geocoded to a short place
    /// name, captured once at recording start). **Off by default** — location never leaves the
    /// device without an explicit opt-in, matching the app's "nothing leaves your device" pitch.
    var locationCaptureEnabled: Bool {
        didSet { defaults.set(locationCaptureEnabled, forKey: Keys.locationCaptureEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // didSet doesn't fire during init, so these loads never write back the default.
        self.whisperModel = defaults.string(forKey: Keys.whisperModel)
            .flatMap(WhisperModel.init(rawValue:)) ?? WhisperModel.platformDefault
        self.diarizerBackend = defaults.string(forKey: Keys.diarizerBackend)
            .flatMap(DiarizerBackend.init(rawValue:)) ?? DiarizerBackend.platformDefault
        self.wordTimestamps = defaults.object(forKey: Keys.wordTimestamps) as? Bool ?? false
        self.autoFollowTranscript = defaults.object(forKey: Keys.autoFollowTranscript) as? Bool ?? true
        self.showConfidence = defaults.object(forKey: Keys.showConfidence) as? Bool ?? false
        self.locationCaptureEnabled = defaults.object(forKey: Keys.locationCaptureEnabled) as? Bool ?? false
    }
}
