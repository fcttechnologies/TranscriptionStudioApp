import Foundation
import SwiftData

/// The recording archive + persistence collaborator: mixes captured chunks into the running
/// audio archive and the diar-track buffer, then, at stop, writes the finished run as a
/// SwiftData session (with the archived/synthesized audio and the Spotlight index). Split out
/// of `RecordingController` so the archive-mixing and the session-write are testable apart
/// from the live capture/fusion loop; the controller still owns the live phase and calls in
/// per chunk and once at stop.
@MainActor
final class RecordingArchiver {
    private let modelContext: ModelContext
    private let recorder: PipelineRecorder
    private let titleGenerator: TitleGenerator
    private let highlightsExtractor: HighlightsExtractor

    /// The full mixed archive so far — every track summed at its session-clock offset. The
    /// inspector's diarizer A/B cross-check runs its pass on these real samples.
    private(set) var archive: [Float] = []
    /// The diar track's raw samples, buffered for a non-streaming diarizer's one full-buffer pass.
    private(set) var diarBuffer: [Float] = []

    init(modelContext: ModelContext, recorder: PipelineRecorder,
         titleGenerator: TitleGenerator = TitleGenerator(),
         highlightsExtractor: HighlightsExtractor = HighlightsExtractor()) {
        self.modelContext = modelContext
        self.recorder = recorder
        self.titleGenerator = titleGenerator
        self.highlightsExtractor = highlightsExtractor
    }

    /// Clear both buffers for a new run.
    func reset() {
        archive = []
        diarBuffer = []
    }

    /// Mix a chunk into the running archive at its session-clock offset — mic and system share
    /// one session clock, so summing yields the full mixed meeting audio.
    func mixIntoArchive(_ chunk: AudioChunk) {
        let startSample = Int(chunk.startTime * AudioChunk.sampleRate)
        let needed = startSample + chunk.samples.count
        if archive.count < needed { archive.append(contentsOf: repeatElement(0, count: needed - archive.count)) }
        for (offset, sample) in chunk.samples.enumerated() {
            archive[startSample + offset] += sample
        }
    }

    /// Buffer a diar-track chunk (positioned by its session clock) for the full-buffer pass.
    func accumulateDiar(_ chunk: AudioChunk) {
        let startSample = Int(chunk.startTime * AudioChunk.sampleRate)
        let needed = startSample + chunk.samples.count
        if diarBuffer.count < needed { diarBuffer.append(contentsOf: repeatElement(0, count: needed - diarBuffer.count)) }
        for (offset, sample) in chunk.samples.enumerated() {
            diarBuffer[startSample + offset] = sample
        }
    }

    /// Persist a finished run as a SwiftData session: the fused transcript segments, the
    /// archived (or synthesized, if nothing was captured) audio, and the Spotlight index.
    /// Returns the session id, or nil when there's nothing to persist.
    func persist(sessionID: UUID,
                mode: RecordingController.Mode,
                elapsed: TimeInterval,
                segments: [AttributedSegment],
                latestTurns: [SpeakerTurn],
                location: RecordingLocationProvider.CapturedLocation? = nil) -> UUID? {
        guard !segments.isEmpty else { return nil }
        let kind: SessionKind = mode == .meeting ? .meetingRecording : .roomRecording
        let session = TranscriptSession(title: Self.defaultTitle(for: mode), kind: kind)
        session.id = sessionID
        session.status = .complete
        session.duration = elapsed
        session.fullText = segments.map(\.asr.text).joined(separator: " ")
        // Opt-in recording-location metadata — set before the Spotlight index below so the place
        // name is folded into the session's keywords on first index (`SessionKeywords`).
        if let location {
            session.locationName = location.name
            session.coordinate = GeoCoordinate(latitude: location.latitude,
                                               longitude: location.longitude)
        }

        // Archive the mixed audio (compressed AAC) so the session is re-playable / re-runnable.
        let samples = archive.isEmpty
            ? AudioFileIO.synthesize(turns: latestTurns.map { ($0.start, $0.end, $0.speakerIndex) },
                                     totalDuration: elapsed)
            : archive
        session.audioData = try? AudioFileIO.encodeAAC(samples: samples)

        for attributed in segments {
            let stored = StoredSegment(from: attributed)
            stored.session = session
            session.segments?.append(stored)
        }
        modelContext.insert(session)
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .persistence,
                                      message: "Session saved",
                                      metadata: ["segments": "\(segments.count)"]))
        try? modelContext.save()
        TranscriptSpotlightIndex.index(session)
        titleGenerator.applyGeneratedTitle(to: session, modelContext: modelContext)
        // The FM extraction substrate — off the critical path, after the session is saved.
        highlightsExtractor.schedule(for: session, modelContext: modelContext)
        return sessionID
    }

    private static func defaultTitle(for mode: RecordingController.Mode) -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        return "\(mode.title) recording · \(stamp)"
    }
}
