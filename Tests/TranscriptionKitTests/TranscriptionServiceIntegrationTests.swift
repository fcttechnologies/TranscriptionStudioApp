import Foundation
import SwiftData
import Testing
@testable import TranscriptionKit

/// End-to-end proof that the real runner drives a real WhisperKit transcription: a real
/// file rides `TranscriptionService.runFileJob` through the actual ASR engine (the diarizer
/// is mocked so this doesn't also require the Sortformer Core AI model), producing a
/// persisted, non-empty, audio-archived session. Set `TS_SKIP_MODEL_TESTS=1` to skip.
@Suite("TranscriptionService — real engine integration", .serialized)
@MainActor
struct TranscriptionServiceIntegrationTests {
    nonisolated static var modelTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["TS_SKIP_MODEL_TESTS"] != "1"
    }

    nonisolated static var testResourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TranscriptionServiceIntegrationTests.swift
            .deletingLastPathComponent() // TranscriptionKitTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("TestResources")
    }

    @Test(.enabled(if: TranscriptionServiceIntegrationTests.modelTestsEnabled))
    func realFileJobTranscribesAndPersists() async throws {
        let wav = Self.testResourcesDir.appendingPathComponent("two_speakers_short.wav")
        #expect(FileManager.default.fileExists(atPath: wav.path),
               "Run scripts/make-verification-audio.sh first")

        let context = ModelContextFactory.makeInMemory()
        let store = InspectorStore()
        let recorder = PipelineRecorder(store: store)
        let service = TranscriptionService(
            asrEngine: WhisperKitAsrEngine(),
            diarizer: MockDiarizationEngine(),
            modelContext: context,
            recorder: recorder,
            inspector: store,
            wordTimestamps: false,
            modelName: WhisperKitAsrEngine.platformDefaultModelName)
        let job = TranscriptionJob(title: "Real file", steps: TranscriptionService.fileJobSteps)

        let sessionID = try #require(await service.runFileJob(fileURL: wav, job: job))
        defer { AudioFileIO.url(forFileName: "\(sessionID.uuidString).wav").map { try? FileManager.default.removeItem(at: $0) } }

        #expect(job.state == .done)
        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(!session.fullText.isEmpty)
        #expect((session.segments?.count ?? 0) > 0)
        #expect(session.audioFileName != nil)
        #expect(session.duration > 0)
    }
}
