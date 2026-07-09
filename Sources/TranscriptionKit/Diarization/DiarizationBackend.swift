// DiarizationBackend — the explicit, cheap seam for choosing the diarizer. SpeakerKit is the
// shipping default (it runs today, fully offline, and drives the ≥85% ground-truth gate);
// Sortformer is opt-in and lights up once a re-exported model loads on the current toolchain
// (see Documentation/SORTFORMER-STATUS.md). The inspector's A/B view builds one of each.
//
// Swapping the default after a re-export is a one-line change (`.default`), and the app can offer
// both to the user without touching engine code.

import Foundation

public enum DiarizationBackend: String, Sendable, CaseIterable, Codable {
    /// Argmax SpeakerKit (Pyannote / CoreML). The working default.
    case speakerKit
    /// NVIDIA Streaming Sortformer on Core AI. Opt-in; supports live streaming.
    case sortformer

    /// The shipping default backend. Flip to `.sortformer` here once the re-export loads.
    public static let `default`: DiarizationBackend = .speakerKit

    public var displayName: String {
        switch self {
        case .speakerKit: "SpeakerKit (Pyannote)"
        case .sortformer: "Sortformer (Core AI)"
        }
    }

    /// Whether this backend supports the live `stream(chunks:)` path (Pyannote is full-clip only).
    public var supportsStreaming: Bool { self == .sortformer }

    /// Build the engine. One place; callers pick a backend, not a concrete type.
    public func makeEngine(recorder: PipelineRecorder? = nil, sessionID: UUID? = nil) -> any DiarizationEngine {
        switch self {
        case .speakerKit:
            return SpeakerKitEngine(recorder: recorder, sessionID: sessionID)
        case .sortformer:
            return SortformerEngine(store: SortformerModelStore(), recorder: recorder, sessionID: sessionID)
        }
    }
}
