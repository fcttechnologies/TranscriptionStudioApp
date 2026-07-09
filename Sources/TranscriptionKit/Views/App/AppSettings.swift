import Foundation
import Observation

/// User-facing model choices, surfaced in the Settings scene. Non-functional stubs for now
/// (the engines self-configure); the shape is here so Settings is real UI, not a placeholder,
/// and so the real engines can read a chosen model without a UI change.
@MainActor
@Observable
public final class AppSettings {
    public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
        case tiny, base, small, largeTurbo, largeV3
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .tiny: "Whisper Tiny"
            case .base: "Whisper Base"
            case .small: "Whisper Small"
            case .largeTurbo: "Whisper Large v3 Turbo"
            case .largeV3: "Whisper Large v3"
            }
        }
        public var detail: String {
            switch self {
            case .tiny: "Fastest · lowest accuracy"
            case .base: "Fast · light"
            case .small: "Balanced"
            case .largeTurbo: "Recommended · fast + accurate"
            case .largeV3: "Most accurate · heaviest"
            }
        }
    }

    public enum DiarizerBackend: String, CaseIterable, Identifiable, Sendable {
        case sortformer, speakerKit
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .sortformer: "Streaming Sortformer"
            case .speakerKit: "SpeakerKit (cross-check)"
            }
        }
        public var detail: String {
            switch self {
            case .sortformer: "On-device · up to 4 speakers · Core AI"
            case .speakerKit: "Argmax baseline · comparison"
            }
        }
    }

    public var whisperModel: WhisperModel = .largeTurbo
    public var diarizerBackend: DiarizerBackend = .sortformer
    /// Capture word-level timestamps (costs decode time) — off by default.
    public var wordTimestamps: Bool = false
    /// Auto-follow the live transcript as it grows (yields to manual scroll).
    public var autoFollowTranscript: Bool = true

    public init() {}
}
