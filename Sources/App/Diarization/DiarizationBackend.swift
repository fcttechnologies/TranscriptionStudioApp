// DiarizationBackend — the explicit, cheap seam for choosing the diarizer. Sortformer (on a
// locally re-exported Core AI model — Documentation/SORTFORMER-MODEL.md) is the default: it
// passes the ground-truth gates and is the only backend with live streaming. SpeakerKit is the
// independent cross-check (the inspector's A/B builds one of each) and the fallback when the
// Sortformer model isn't provisioned. Swapping defaults is a one-line change (`.default`).

import Foundation

enum DiarizationBackend: String, Sendable, CaseIterable, Codable {
    /// Argmax SpeakerKit (Pyannote / CoreML). The working default.
    case speakerKit
    /// NVIDIA Streaming Sortformer on Core AI. Opt-in; supports live streaming.
    case sortformer

    /// The shipping default backend.
    static let `default`: DiarizationBackend = .sortformer

    var displayName: String {
        switch self {
        case .speakerKit: "SpeakerKit (Pyannote)"
        case .sortformer: "Sortformer (Core AI)"
        }
    }

    /// Whether this backend supports the live `stream(chunks:)` path (Pyannote is full-clip only).
    var supportsStreaming: Bool { self == .sortformer }

    /// Build the engine. One place; callers pick a backend, not a concrete type.
    func makeEngine(recorder: PipelineRecorder? = nil, sessionID: UUID? = nil,
                           sortformerStore: SortformerModelStore = SortformerModelStore()) -> any DiarizationEngine {
        switch self {
        case .speakerKit:
            return SpeakerKitEngine(recorder: recorder, sessionID: sessionID)
        case .sortformer:
            // The published Sortformer model FATALLY (uncatchably) aborts the process on load on
            // the current toolchain; only a locally re-exported model — which stages a local
            // manifest — is safe. Without one (iOS, or any un-provisioned machine), fall back to
            // SpeakerKit instead of crashing. See Documentation/SORTFORMER-MODEL.md.
            guard sortformerStore.hasLocalManifest else {
                return SpeakerKitEngine(recorder: recorder, sessionID: sessionID)
            }
            return SortformerEngine(store: sortformerStore, recorder: recorder, sessionID: sessionID)
        }
    }
}
