// `TranscriptSessionEntity`'s AppIntents display metadata (untouched by `SiriIntelligenceTests`,
// which only exercises the `TranscriptSessionStore` query functions against an injected
// container) plus the entry points that only ever run against the real `AppModelContainer.shared`
// singleton: the entity's `typeDisplayRepresentation`/`displayRepresentation`, the
// `TranscriptSessionEntityQuery` (whose `EntityStringQuery` signatures can't take a container
// parameter, so it always reads `.shared`), and `.shared` itself.
//
// `.serialized`: every test here touches the one process-wide `AppModelContainer.shared`
// singleton (in-memory under `isRunningTests`), so they must not interleave.

import Testing
import Foundation
import SwiftData
@testable import TranscriptionStudio

@Suite("TranscriptSessionEntity — display + shared-container query path", .serialized)
@MainActor
struct TranscriptSessionEntityDisplayTests {

    @Test func displayRepresentationOmitsDurationWhenZero() {
        let date = Date()
        let entity = TranscriptSessionEntity(id: UUID().uuidString, title: "Standup",
                                             date: date, kindLabel: "Room recording",
                                             duration: 0, textPreview: "notes")
        let rep = entity.displayRepresentation
        #expect(String(localized: rep.title) == "Standup")
        let subtitle = rep.subtitle.map { String(localized: $0) } ?? ""
        let dateString = date.formatted(date: .abbreviated, time: .shortened)
        // Just kind + date — no third (clock) part appended when duration is 0.
        #expect(subtitle == "Room recording · \(dateString)")
    }

    @Test func displayRepresentationAppendsClockWhenDurationIsPositive() {
        let date = Date()
        let entity = TranscriptSessionEntity(id: UUID().uuidString, title: "Standup",
                                             date: date, kindLabel: "Room recording",
                                             duration: 125, textPreview: "notes")
        let rep = entity.displayRepresentation
        let subtitle = rep.subtitle.map { String(localized: $0) } ?? ""
        let dateString = date.formatted(date: .abbreviated, time: .shortened)
        #expect(subtitle == "Room recording · \(dateString) · \(TimeFormat.clock(125))")
    }

    @Test func typeDisplayRepresentationCarriesANonEmptyName() {
        let rep = TranscriptSessionEntity.typeDisplayRepresentation
        #expect(String(localized: rep.name) == "Transcript")
        #expect(rep.numericFormat != nil)
    }

    // MARK: AppModelContainer.shared

    @Test func sharedContainerIsInMemoryUnderTestsAndUsesTheAppSchema() {
        #expect(AppModelContainer.isRunningTests)
        let container = AppModelContainer.shared
        #expect(container.schema.entities.map(\.name).sorted()
            == AppModelContainer.schema.entities.map(\.name).sorted())
        // A fresh context against it round-trips a session (proves it's a real, usable store).
        let context = ModelContext(container)
        let probe = TranscriptSession(title: "AppModelContainer.shared probe", kind: .fileTranscription)
        context.insert(probe)
        #expect(throws: Never.self) { try context.save() }
    }

    // MARK: TranscriptSessionEntityQuery (always reads AppModelContainer.shared)

    private func insertIntoShared(title: String) -> UUID {
        let context = ModelContext(AppModelContainer.shared)
        let session = TranscriptSession(title: title, kind: .roomRecording)
        session.fullText = "unique marker text for the entity query test"
        context.insert(session)
        try? context.save()
        return session.id
    }

    @Test func entitiesForIdentifiersResolvesFromTheSharedContainer() async throws {
        let id = insertIntoShared(title: "Query-by-id probe")
        let resolved = try await TranscriptSessionEntityQuery().entities(for: [id.uuidString])
        #expect(resolved.count == 1)
        #expect(resolved.first?.title == "Query-by-id probe")
    }

    @Test func entitiesForUnknownIdentifierStringsResolveToNothing() async throws {
        let resolved = try await TranscriptSessionEntityQuery().entities(for: ["not-a-uuid"])
        #expect(resolved.isEmpty)
    }

    @Test func entitiesMatchingSearchesTheSharedContainer() async throws {
        let nonce = "Nonce-\(UUID().uuidString.prefix(8))"
        _ = insertIntoShared(title: nonce)
        let hits = try await TranscriptSessionEntityQuery().entities(matching: nonce)
        #expect(hits.contains { $0.title == nonce })
    }

    @Test func suggestedEntitiesReturnsRecentSessionsFromTheSharedContainer() async throws {
        let id = insertIntoShared(title: "Suggested-entities probe")
        let suggested = try await TranscriptSessionEntityQuery().suggestedEntities()
        #expect(suggested.contains { $0.id == id.uuidString })
    }
}
