// RecordingArchiver owns the archive-mixing and finished-run persistence split out of
// RecordingController — these tests exercise it directly, apart from the live capture loop:
// mixIntoArchive's session-clock summing, accumulateDiar's track buffering, and persist's
// session-write (including the empty-archive synthesize fallback and the nothing-to-persist nil).

import Foundation
import Testing
import SwiftData
@testable import TranscriptionKit

@Suite("RecordingArchiver")
@MainActor
struct RecordingArchiverTests {

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func makeArchiver(context: ModelContext) -> RecordingArchiver {
        let inspector = InspectorStore()
        let recorder = PipelineRecorder(store: inspector)
        return RecordingArchiver(modelContext: context, recorder: recorder)
    }

    private func segment(text: String, start: TimeInterval = 0) -> AttributedSegment {
        AttributedSegment(asr: AsrSegment(track: .mixed, start: start, end: start + 1, text: text),
                          speaker: .speaker(0), speakerConfidence: 0.9, isProvisional: false)
    }

    // MARK: - mixIntoArchive

    @Test func mixIntoArchiveSumsOverlappingChunksAtTheirSessionClockOffset() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        // Two tracks sharing the same clock window (mic + system in meeting mode) should sum.
        let mic = AudioChunk(track: .microphone, samples: [1, 1, 1], startTime: 0)
        let system = AudioChunk(track: .system, samples: [0.5, 0.5, 0.5], startTime: 0)
        archiver.mixIntoArchive(mic)
        archiver.mixIntoArchive(system)

        #expect(archiver.archive.count == 3)
        for sample in archiver.archive { #expect(abs(sample - 1.5) < 0.0001) }
    }

    @Test func mixIntoArchiveZeroFillsTheGapBeforeALaterOffsetChunk() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        // A chunk starting at 1s (16,000 samples in) with 16kHz sample rate — the gap before it
        // must be zero-filled, not skipped, so later chunks land at the right offset.
        let startTime: TimeInterval = 1.0
        let chunk = AudioChunk(track: .mixed, samples: [0.3, 0.3], startTime: startTime)
        archiver.mixIntoArchive(chunk)

        let startSample = Int(startTime * AudioChunk.sampleRate)
        #expect(archiver.archive.count == startSample + 2)
        #expect(archiver.archive[0..<startSample].allSatisfy { $0 == 0 })
        #expect(abs(archiver.archive[startSample] - 0.3) < 0.0001)
        #expect(abs(archiver.archive[startSample + 1] - 0.3) < 0.0001)
    }

    @Test func mixIntoArchiveGrowsTheBufferAsLaterChunksArrive() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        archiver.mixIntoArchive(AudioChunk(track: .mixed, samples: [1, 1], startTime: 0))
        #expect(archiver.archive.count == 2)
        archiver.mixIntoArchive(AudioChunk(track: .mixed, samples: [1, 1], startTime: 0.5))
        // 0.5s at 16kHz = 8000 samples in, plus 2 more.
        #expect(archiver.archive.count == Int(0.5 * AudioChunk.sampleRate) + 2)
    }

    // MARK: - accumulateDiar

    @Test func accumulateDiarOverwritesRatherThanSummingAtItsOffset() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        archiver.accumulateDiar(AudioChunk(track: .system, samples: [0.2, 0.2], startTime: 0))
        archiver.accumulateDiar(AudioChunk(track: .system, samples: [0.9, 0.9], startTime: 0))

        // Overwrite semantics (assignment, not +=) — the second chunk replaces the first at
        // the same offset rather than mixing with it.
        #expect(archiver.diarBuffer.count == 2)
        for sample in archiver.diarBuffer { #expect(abs(sample - 0.9) < 0.0001) }
    }

    @Test func accumulateDiarZeroFillsGapsLikeMixIntoArchive() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        archiver.accumulateDiar(AudioChunk(track: .system, samples: [0.4], startTime: 0.25))
        let startSample = Int(0.25 * AudioChunk.sampleRate)
        #expect(archiver.diarBuffer.count == startSample + 1)
        #expect(archiver.diarBuffer[0..<startSample].allSatisfy { $0 == 0 })
    }

    // MARK: - reset

    @Test func resetClearsBothBuffers() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)
        archiver.mixIntoArchive(AudioChunk(track: .mixed, samples: [1, 1], startTime: 0))
        archiver.accumulateDiar(AudioChunk(track: .mixed, samples: [1, 1], startTime: 0))
        #expect(!archiver.archive.isEmpty)
        #expect(!archiver.diarBuffer.isEmpty)

        archiver.reset()
        #expect(archiver.archive.isEmpty)
        #expect(archiver.diarBuffer.isEmpty)
    }

    // MARK: - persist

    @Test func persistReturnsNilAndWritesNothingWhenThereAreNoSegments() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        let id = archiver.persist(sessionID: UUID(), mode: .room, elapsed: 5,
                                  segments: [], latestTurns: [])
        #expect(id == nil)
        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.isEmpty)
    }

    @Test func persistWritesTheMixedArchiveAudioWhenSomethingWasCaptured() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)
        archiver.mixIntoArchive(AudioChunk(track: .mixed, samples: [Float](repeating: 0.1, count: 1_600),
                                           startTime: 0))
        let sessionID = UUID()

        let id = archiver.persist(sessionID: sessionID, mode: .room, elapsed: 0.1,
                                  segments: [segment(text: "hello")], latestTurns: [])
        #expect(id == sessionID)

        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        let session = try #require(sessions.first)
        #expect(session.id == sessionID)
        #expect(session.kind == .roomRecording)
        #expect(session.status == .complete)
        #expect(session.fullText == "hello")
        #expect((session.segments ?? []).count == 1)
        let name = try #require(session.audioFileName)
        let url = try #require(AudioFileIO.url(forFileName: name))
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func persistSynthesizesAudioFromTurnsWhenNothingWasCaptured() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)
        // archive stays empty — nothing was mixed in — so persist must fall back to synthesis.
        #expect(archiver.archive.isEmpty)
        let sessionID = UUID()
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 1, confidence: 0.9)]

        let id = archiver.persist(sessionID: sessionID, mode: .meeting, elapsed: 1,
                                  segments: [segment(text: "synth path")], latestTurns: turns)
        #expect(id == sessionID)

        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(session.kind == .meetingRecording)
        let name = try #require(session.audioFileName)
        let url = try #require(AudioFileIO.url(forFileName: name))
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The synthesized file is non-trivial in size (not an empty/near-empty WAV).
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require(attrs[.size] as? Int)
        #expect(size > 44)   // more than just the WAV header
        try? FileManager.default.removeItem(at: url)
    }

    @Test func persistJoinsMultipleSegmentsFullTextWithSpaces() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)
        let sessionID = UUID()

        let id = archiver.persist(sessionID: sessionID, mode: .room, elapsed: 2,
                                  segments: [segment(text: "one", start: 0), segment(text: "two", start: 1)],
                                  latestTurns: [])
        #expect(id != nil)
        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(session.fullText == "one two")
        if let name = session.audioFileName, let url = AudioFileIO.url(forFileName: name) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
