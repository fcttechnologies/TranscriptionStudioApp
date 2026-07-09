import Foundation
import Testing
import SwiftData
@testable import TranscriptionKit

/// End-to-end verification that the recording loop is real: capture → ASR + diarization →
/// fusion → inspector → persisted session, entirely on the mock engines.
@Suite("Recording flow (mocks)")
@MainActor
struct RecordingFlowTests {

    private func makeController(context: ModelContext) -> (RecordingController, InspectorStore) {
        let inspector = InspectorStore()
        let recorder = PipelineRecorder(store: inspector)
        let controller = RecordingController(
            asr: MockAsrEngine(),
            diarizer: MockDiarizationEngine(),
            recorder: recorder,
            inspector: inspector,
            loadSampler: SystemLoadSampler(store: inspector),
            modelContext: context,
            settings: AppSettings())
        return (controller, inspector)
    }

    @Test func liveRunProducesTranscriptEventsAndPersistsSession() async throws {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let (controller, inspector) = makeController(context: context)

        controller.start(mode: .room)
        #expect(controller.isRecording)

        // Wait for the mock stream to produce fused transcript segments.
        try await waitUntil(timeout: 6) { !controller.segments.isEmpty }
        #expect(!controller.segments.isEmpty)
        #expect(!inspector.events.isEmpty)
        #expect(controller.elapsed > 0)

        let sessionID = await controller.stop()
        #expect(sessionID != nil)
        #expect(!controller.isRecording)

        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(!(session.segments ?? []).isEmpty)
        #expect(session.kind == .roomRecording)
        #expect(session.audioFileName != nil)
        #expect(!session.fullText.isEmpty)

        // The archived audio file was actually written.
        let name = try #require(session.audioFileName)
        let url = try #require(AudioFileIO.url(forFileName: name))
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func meetingModeAttributesLocalUserAsMe() async throws {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let (controller, _) = makeController(context: context)

        controller.start(mode: .meeting)
        try await waitUntil(timeout: 6) {
            controller.segments.contains { $0.speaker == .me }
        }
        #expect(controller.segments.contains { $0.speaker == .me })
        let id = await controller.stop()
        #expect(id != nil)
        if let name = (try? context.fetch(FetchDescriptor<TranscriptSession>()))?.first?.audioFileName,
           let url = AudioFileIO.url(forFileName: name) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func seedSampleSessionIsIdempotent() throws {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        DemoContent.seedSampleSession(into: context)
        let after = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(after.count == 1)
        let session = try #require(after.first)
        #expect((session.segments ?? []).count == 6)
        #expect(session.audioFileName != nil)
        if let name = session.audioFileName, let url = AudioFileIO.url(forFileName: name) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Poll a main-actor condition until it holds or the timeout elapses.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
