import Foundation

/// The three on-device speech models the app runs, each a directory of compiled Core ML models
/// under one root. The name is the directory name, in the manifest, in the hosted repo, in the
/// App Group staging area and on disk, so one identifier walks a file from the server to the
/// engine that loads it.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    /// Parakeet TDT 0.6B v3: the recognizer for the 25 European languages.
    case parakeet = "parakeet-v3"
    /// SenseVoiceSmall: the recognizer for Chinese, Cantonese, Japanese and Korean.
    case senseVoice = "sensevoice"
    /// Streaming Sortformer v2.1: the speaker diarizer, up to four speakers.
    case sortformer = "sortformer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .senseVoice: "SenseVoice"
        case .sortformer: "Streaming Sortformer"
        }
    }

    var detail: String {
        switch self {
        case .parakeet: "Speech recognition · European languages"
        case .senseVoice: "Speech recognition · Chinese, Japanese, Korean"
        case .sortformer: "Speaker diarization · up to 4 speakers"
        }
    }

    /// `~/Library/Application Support/TranscriptionStudio/Models/fctspeech`, beside the synthesis
    /// engine's own download base.
    static func root() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionStudio/Models/fctspeech", isDirectory: true)
    }

    /// This model's directory under `root`.
    func directory(under root: URL = SpeechModel.root()) -> URL {
        root.appendingPathComponent(rawValue, isDirectory: true)
    }
}
