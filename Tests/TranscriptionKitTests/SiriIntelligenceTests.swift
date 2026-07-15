import Testing
import Foundation
import SwiftData
import FCTEntities
@testable import TranscriptionKit

/// The Siri/App-Intents entity query and the on-device intelligence availability gate.
/// Both run against in-memory state / injected status — no Apple Intelligence hardware needed.
@MainActor
struct SiriIntelligenceTests {

    // MARK: Entity string query

    private func makeStore() throws -> ModelContainer {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let budget = TranscriptSession(title: "Budget meeting", kind: .roomRecording)
        budget.fullText = "We reviewed the quarterly numbers and hiring plan."
        context.insert(budget)

        let walk = TranscriptSession(title: "Dog walk notes", kind: .roomRecording)
        walk.fullText = "Talked through the marketing budget for next year."
        context.insert(walk)

        try context.save()
        return container
    }

    @Test func stringQueryMatchesTitle() throws {
        let container = try makeStore()
        let hits = TranscriptSessionStore.entities(matching: "dog", in: container)
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Dog walk notes")
    }

    @Test func stringQueryMatchesFullText() throws {
        let container = try makeStore()
        // "quarterly" appears only in the Budget session's transcript, not any title.
        let hits = TranscriptSessionStore.entities(matching: "quarterly", in: container)
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Budget meeting")
    }

    @Test func stringQueryMatchesTitleOrFullTextTogether() throws {
        let container = try makeStore()
        // "budget" is in one title and the other's transcript — both should match.
        let hits = TranscriptSessionStore.entities(matching: "budget", in: container)
        #expect(hits.count == 2)
    }

    @Test func emptyQueryReturnsAllNewestFirst() throws {
        let container = try makeStore()
        let all = TranscriptSessionStore.entities(matching: "", in: container)
        #expect(all.count == 2)
    }

    @Test func resolvesByIdentifierAndCarriesFullText() throws {
        let container = try makeStore()
        let all = TranscriptSessionStore.entities(matching: "", in: container)
        let target = try #require(all.first { $0.title == "Budget meeting" })
        let id = try #require(UUID(uuidString: target.id))

        let resolved = TranscriptSessionStore.entities(withIDs: [id], in: container)
        #expect(resolved.count == 1)
        #expect(resolved.first?.title == "Budget meeting")

        let pair = try #require(TranscriptSessionStore.entityAndText(forID: id, in: container))
        #expect(pair.fullText.contains("quarterly"))
    }

    @Test func latestEntityAndTextReturnsNewest() throws {
        let container = try makeStore()
        let latest = try #require(TranscriptSessionStore.latestEntityAndText(in: container))
        // The dog-walk session was inserted last, so it's newest.
        #expect(latest.entity.title == "Dog walk notes")
        #expect(latest.fullText.contains("marketing budget"))
    }

    @Test func entityCarriesDisplayFields() throws {
        let container = try makeStore()
        let entity = try #require(TranscriptSessionStore.entities(matching: "dog", in: container).first)
        #expect(UUID(uuidString: entity.id) != nil)
        #expect(entity.kindLabel == "Room recording")
        #expect(!entity.textPreview.isEmpty)
    }

    // MARK: Export (ExportTranscriptIntent's backing store methods)

    /// A store whose one session carries real `StoredSegment`s — `TranscriptExport` renders
    /// from segments, not the denormalized `fullText`, so exercising it needs the relationship.
    private func makeSegmentedStore() throws -> (container: ModelContainer, sessionID: UUID) {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let session = TranscriptSession(title: "Standup notes", kind: .roomRecording)
        session.fullText = "We reviewed the quarterly roadmap."
        let segment = StoredSegment(start: 0, end: 3, text: "We reviewed the quarterly roadmap.")
        segment.session = session
        session.segments = [segment]
        context.insert(session)
        try context.save()
        return (container, session.id)
    }

    @Test func exportedTextRendersPlainTextByID() throws {
        let (container, id) = try makeSegmentedStore()
        let exported = try #require(TranscriptSessionStore.exportedText(forID: id, as: .plainText, in: container))
        #expect(exported.title == "Standup notes")
        #expect(exported.text.contains("quarterly roadmap"))
    }

    @Test func latestExportedTextRendersAsMarkdown() throws {
        let (container, _) = try makeSegmentedStore()
        let exported = try #require(TranscriptSessionStore.latestExportedText(as: .markdown, in: container))
        #expect(exported.title == "Standup notes")
        #expect(exported.text.contains("# Standup notes"))
        #expect(exported.text.contains("quarterly roadmap"))
    }

    @Test func exportedTextReturnsNilForUnknownID() throws {
        let (container, _) = try makeSegmentedStore()
        #expect(TranscriptSessionStore.exportedText(forID: UUID(), as: .srt, in: container) == nil)
    }

    // MARK: App Shortcuts capacity

    @Test func shortcutCountWithinSystemLimit() {
        let contract = AppShortcutContract(declaredCount: TranscriptionShortcuts.appShortcuts.count)
        #expect(contract.isWithinLimit)
        #expect(contract.declaredCount == 10)   // pin the exact count so a regression is loud
    }

    // MARK: Intelligence availability gate

    private func unavailable(_ reason: IntelligenceUnavailable) -> SessionIntelligence {
        SessionIntelligence(statusProvider: { .unavailable(reason) })
    }

    @Test func unavailableStatusReportsNotReady() {
        let intelligence = unavailable(.deviceNotEligible)
        #expect(!intelligence.status.isAvailable)
        #expect(!intelligence.status.message.isEmpty)
    }

    @Test func summarizeThrowsUnavailableRatherThanCrashing() async {
        let intelligence = unavailable(.appleIntelligenceNotEnabled)
        await #expect(throws: IntelligenceError.self) {
            _ = try await intelligence.summarize(transcript: "Some spoken content here.")
        }
    }

    @Test func answerThrowsUnavailableWithMappedMessage() async throws {
        let intelligence = unavailable(.deviceNotEligible)
        do {
            _ = try await intelligence.answer(question: "What was decided?",
                                              transcript: "We agreed to ship on Friday.")
            Issue.record("Expected an unavailable error")
        } catch let error as IntelligenceError {
            #expect(error == .unavailable(IntelligenceUnavailable.deviceNotEligible.message))
            #expect(SessionIntelligence.errorMessage(for: error)
                == IntelligenceUnavailable.deviceNotEligible.message)
        }
    }

    @Test func availableButEmptyTranscriptThrowsBeforeGenerating() async {
        // Status available, but no content — the guard fires before any model call, so this
        // is safe to run without Apple Intelligence hardware.
        let intelligence = SessionIntelligence(statusProvider: { .available })
        await #expect(throws: IntelligenceError.emptyTranscript) {
            _ = try await intelligence.summarize(transcript: "   ")
        }
    }

    @Test func unavailableReasonMessagesAreDistinctAndNonEmpty() {
        let reasons: [IntelligenceUnavailable] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .notSupported
        ]
        for reason in reasons { #expect(!reason.message.isEmpty) }
        #expect(IntelligenceUnavailable.appleIntelligenceNotEnabled.message
            != IntelligenceUnavailable.modelNotReady.message)
    }
}
