import FCTDictation
import FCTSpeech
import Foundation

/// Transcription Studio's own engines plugged into `FCTDictation`'s two seams.
///
/// Both wrap engines the app already ships and already prepares for its real pipeline, so a
/// dictation costs no second model: the recognizer here is the one a transcription job uses, and
/// the diarizer is the same.
///
/// Neither is the default. Apple's `SpeechTranscriber` downloads nothing of ours and is what a
/// dictation runs on until the person chooses otherwise in Settings — these are the improvement
/// they opt into, and their models are the download that opt-in pays for.

/// The studio's recognizer as the improved ``DictationEngine``.
///
/// `AsrEngine` speaks 16 kHz mono samples and `DictationRecording` is a file, so the one thing
/// this adds is the read between them. It reads the file directly rather than through
/// `FileIngestService`: that gate exists to reject a hostile *upload* by extension, and the
/// recorder's own `.caf` is neither an upload nor on its whitelist.
nonisolated final class StudioDictationEngine: DictationEngine {

    static let engineIdentifier = "transcriptionstudio.studio"

    private let engine: any AsrEngine

    init(engine: any AsrEngine) {
        self.engine = engine
    }

    var identifier: String { Self.engineIdentifier }

    func prepare(onProgress: @escaping @Sendable (DictationPreparationProgress) -> Void) async throws {
        try await engine.prepare { progress in
            onProgress(DictationPreparationProgress(phase: progress.phase, fraction: progress.fraction))
        }
    }

    func transcribe(_ recording: DictationRecording) async throws -> DictationTranscript {
        let samples = try DictationAudio.samples(at: recording.url)
        let segments = try await engine.transcribe(samples: samples, track: .mixed, wordTimestamps: false)
        return DictationTranscript(
            segments: segments.map { DictationSegment(text: $0.text, start: $0.start, end: $0.end) },
            // The route picks the model from the interface locale, and the engine reports the
            // language on no segment, so nothing here knows which locale it transcribed in. Nil
            // is that, rather than `Locale.current` standing in for a fact nothing here knows.
            locale: nil,
            engineIdentifier: identifier
        )
    }
}

/// The diarizer as a ``DictationTranscriptPass`` — the stage between the engine and cleanup that
/// fills in each segment's speaker.
///
/// Attribution is `TranscriptFuser`'s, unchanged: it is the app's proven overlap math and the
/// thing "who said what" is decided by, so a dictation gets the same answer the library does
/// rather than a second implementation that could disagree with it. A segment no turn covers
/// stays unlabelled — `.unknown` is the fuser saying it does not know, and writing that word onto
/// a line would read as a speaker named Unknown.
nonisolated final class SpeakerDictationPass: DictationTranscriptPass {

    private let diarizer: any DiarizationEngine

    init(diarizer: any DiarizationEngine) {
        self.diarizer = diarizer
    }

    func run(
        _ transcript: DictationTranscript, on recording: DictationRecording
    ) async throws -> DictationTranscript {
        let samples = try DictationAudio.samples(at: recording.url)
        try await diarizer.prepare { _ in }
        let diarization = try await diarizer.diarize(samples: samples)

        return DictationTranscript(
            segments: Self.labelled(transcript.segments, with: diarization.turns),
            locale: transcript.locale,
            engineIdentifier: transcript.engineIdentifier
        )
    }

    /// The mapping, pure: segments in, segments with speakers out.
    static func labelled(_ segments: [DictationSegment], with turns: [SpeakerTurn]) -> [DictationSegment] {
        let asr = segments.map {
            AsrSegment(track: .mixed, start: $0.start, end: $0.end, text: $0.text)
        }
        let attributed = TranscriptFuser.attribute(asr: asr, turns: turns)
        return zip(segments, attributed).map { segment, attribution in
            var copy = segment
            copy.speaker = attribution.speaker == .unknown ? nil : attribution.speaker.displayName
            return copy
        }
    }
}

/// The one read both seams need: a finished dictation recording as the 16 kHz mono samples every
/// engine in this app speaks.
enum DictationAudio {
    static func samples(at url: URL) throws -> [Float] {
        try AudioFileReader.monoFloat16k(url)
    }
}
