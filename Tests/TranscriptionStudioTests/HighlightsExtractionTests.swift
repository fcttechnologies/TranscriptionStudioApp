import Testing
import Foundation
import SwiftData
@testable import TranscriptionStudio

/// The FM extraction substrate's *deterministic* half — the mapping from a `SessionHighlights`
/// value into the real, queryable SwiftData `@Model` types, and the concrete-date resolution — both
/// exercised without a live model (the model's output is supplied directly).
@MainActor
struct HighlightsExtractionTests {

    private func makeStore() throws -> (ModelContainer, ModelContext, TranscriptSession) {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Budget meeting", kind: .roomRecording)
        session.fullText = "We reviewed the numbers."
        context.insert(session)
        try context.save()
        return (container, context, session)
    }

    @Test func applyMapsEveryCategoryIntoRealModels() throws {
        let (_, context, session) = try makeStore()
        let highlights = SessionHighlights(
            decisions: ["Ship the redesign on Friday"],
            actionItems: [ExtractedActionItem(task: "Send the deck", owner: "Sergio", dueDateText: "by Friday")],
            events: [ExtractedEvent(title: "Design review", dateText: "July 20, 2026", attendees: ["Ana", "Sergio"])],
            people: ["Sergio", "Ana"],
            places: ["the office"]
        )

        HighlightsExtractor.apply(highlights, to: session, modelContext: context)

        #expect(session.highlightsStatus == .ready)
        #expect(session.decisions?.count == 1)
        #expect(session.decisions?.first?.text == "Ship the redesign on Friday")
        #expect(session.actionItems?.count == 1)
        #expect(session.actionItems?.first?.task == "Send the deck")
        #expect(session.actionItems?.first?.owner == "Sergio")
        #expect(session.events?.count == 1)
        #expect(session.events?.first?.attendees == ["Ana", "Sergio"])
        #expect(session.people?.count == 2)
        #expect(session.places?.first?.name == "the office")
    }

    @Test func applyResolvesAbsoluteDatesAndDropsEmptyOptionalFields() throws {
        let (_, context, session) = try makeStore()
        let highlights = SessionHighlights(
            actionItems: [ExtractedActionItem(task: "Prep", owner: "", dueDateText: "July 20, 2026")],
            events: [ExtractedEvent(title: "Kickoff", dateText: "January 5, 2027", attendees: [])]
        )

        HighlightsExtractor.apply(highlights, to: session, modelContext: context)

        let action = try #require(session.actionItems?.first)
        #expect(action.owner == nil)                      // "" → nil
        #expect(action.dueDateText == "July 20, 2026")
        let dueComponents = Calendar.current.dateComponents([.year, .month, .day], from: try #require(action.dueDate))
        #expect(dueComponents.year == 2026 && dueComponents.month == 7 && dueComponents.day == 20)

        let event = try #require(session.events?.first)
        let eventComponents = Calendar.current.dateComponents([.year, .month, .day], from: try #require(event.date))
        #expect(eventComponents.year == 2027 && eventComponents.month == 1 && eventComponents.day == 5)
    }

    @Test func applySkipsBlankItems() throws {
        let (_, context, session) = try makeStore()
        let highlights = SessionHighlights(
            decisions: ["", "   ", "A real decision"],
            people: ["", "Sergio"]
        )

        HighlightsExtractor.apply(highlights, to: session, modelContext: context)

        #expect(session.decisions?.count == 1)
        #expect(session.decisions?.first?.text == "A real decision")
        #expect(session.people?.count == 1)
    }

    @Test func applyReplacesPriorExtractionOnReRun() throws {
        let (_, context, session) = try makeStore()

        HighlightsExtractor.apply(SessionHighlights(decisions: ["First pass"]), to: session, modelContext: context)
        #expect(session.decisions?.count == 1)

        HighlightsExtractor.apply(SessionHighlights(decisions: ["Second pass A", "Second pass B"]),
                                  to: session, modelContext: context)
        #expect(session.decisions?.count == 2)
        #expect(session.decisions?.contains { $0.text == "First pass" } == false)
    }

    // MARK: - RelativeDateResolver

    @Test func resolvesAnAbsoluteDatePhrase() throws {
        let date = try #require(RelativeDateResolver.resolve("July 20, 2026"))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        #expect(components.year == 2026 && components.month == 7 && components.day == 20)
    }

    @Test func returnsNilForAPhraseWithNoDate() {
        #expect(RelativeDateResolver.resolve("") == nil)
        #expect(RelativeDateResolver.resolve("sometime, no clear date here") == nil)
    }
}
