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
        // No Apple Intelligence hardware needed: title-gen's model path is exercised in
        // TitleGeneratorTests, not here.
        let titleGenerator = TitleGenerator(statusProvider: { .unavailable(.notSupported) })
        return RecordingArchiver(modelContext: context, recorder: recorder, titleGenerator: titleGenerator)
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
        // The mixed audio was archived as compressed AAC data in the session row, and it
        // decodes back to real samples.
        let audioData = try #require(session.audioData)
        #expect(!audioData.isEmpty)
        #expect(try !AudioFileIO.decodeAAC(audioData).isEmpty)
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
        // The synthesized audio was encoded and archived — non-trivial compressed data.
        let audioData = try #require(session.audioData)
        #expect(audioData.count > 100)
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
    }

    @Test func persistAttachesTheCapturedLocationWhenProvided() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)
        let location = RecordingLocationProvider.CapturedLocation(
            name: "Mission District, San Francisco", latitude: 37.7599, longitude: -122.4148)

        let id = archiver.persist(sessionID: UUID(), mode: .room, elapsed: 3,
                                  segments: [segment(text: "hi")], latestTurns: [], location: location)
        #expect(id != nil)

        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(session.locationName == "Mission District, San Francisco")
        #expect(session.coordinate == GeoCoordinate(latitude: 37.7599, longitude: -122.4148))
    }

    @Test func persistLeavesLocationNilWhenNoneCaptured() throws {
        let context = try inMemoryContext()
        let archiver = makeArchiver(context: context)

        _ = archiver.persist(sessionID: UUID(), mode: .room, elapsed: 3,
                             segments: [segment(text: "hi")], latestTurns: [])
        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(session.locationName == nil)
        #expect(session.coordinate == nil)
    }
}
