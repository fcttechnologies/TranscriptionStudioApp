import Testing
import Foundation
import SwiftData
@testable import TranscriptionKit

/// The suggestion-chip surface's pure logic: the extraction→chip mapping (kinds, stable ids,
/// deterministic ordering, staleness/`done` filters) and the per-item dismissal — all exercised
/// against an in-memory store, no UI.
@MainActor
struct ActionSuggestionsTests {

    /// A fixed "now" so staleness filtering is deterministic.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (ModelContainer, ModelContext, TranscriptSession) {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Budget meeting", kind: .roomRecording)
        context.insert(session)
        try context.save()
        return (container, context, session)
    }

    private func attach(event: TranscriptEvent, to session: TranscriptSession, in context: ModelContext) {
        context.insert(event)
        event.session = session
    }

    private func attach(item: TranscriptActionItem, to session: TranscriptSession, in context: ModelContext) {
        context.insert(item)
        item.session = session
    }

    private func attach(person: TranscriptPerson, to session: TranscriptSession, in context: ModelContext) {
        context.insert(person)
        person.session = session
    }

    // MARK: Mapping

    @Test func nothingIsSuggestedUntilExtractionIsReady() throws {
        let (_, context, session) = try makeStore()
        attach(event: TranscriptEvent(title: "Design review", date: now.addingTimeInterval(86_400)),
               to: session, in: context)

        session.highlightsStatus = .pending
        #expect(ActionSuggestions.suggestions(for: session, includeContacts: true, now: now).isEmpty)
        session.highlightsStatus = .unavailable
        #expect(ActionSuggestions.suggestions(for: session, includeContacts: true, now: now).isEmpty)
        session.highlightsStatus = .ready
        #expect(ActionSuggestions.suggestions(for: session, includeContacts: true, now: now).count == 1)
    }

    @Test func mapsEachExtractedKindWithStableIDs() throws {
        let (_, context, session) = try makeStore()
        let event = TranscriptEvent(title: "Design review", dateText: "next Tuesday",
                                    date: now.addingTimeInterval(86_400))
        let item = TranscriptActionItem(task: "Send the deck", dueDate: now.addingTimeInterval(3_600))
        let person = TranscriptPerson(name: "Sergio")
        attach(event: event, to: session, in: context)
        attach(item: item, to: session, in: context)
        attach(person: person, to: session, in: context)
        session.highlightsStatus = .ready

        let chips = ActionSuggestions.suggestions(for: session, includeContacts: true, now: now)

        #expect(chips.count == 3)
        let calendar = try #require(chips.first { $0.kind == .calendarEvent })
        #expect(calendar.id == "event:\(event.id.uuidString)")
        #expect(calendar.detail == "Design review")
        #expect(calendar.date == event.date)
        #expect(calendar.itemID == event.id)
        let reminder = try #require(chips.first { $0.kind == .reminder })
        #expect(reminder.id == "reminder:\(item.id.uuidString)")
        #expect(reminder.detail == "Send the deck")
        let contact = try #require(chips.first { $0.kind == .contact })
        #expect(contact.id == "contact:\(person.id.uuidString)")
        #expect(contact.detail == "Sergio")
        #expect(contact.date == nil)
    }

    @Test func ordersKindsThenDatedBeforeUndated() throws {
        let (_, context, session) = try makeStore()
        attach(event: TranscriptEvent(title: "Undated retro"), to: session, in: context)
        attach(event: TranscriptEvent(title: "Late kickoff", date: now.addingTimeInterval(172_800)),
               to: session, in: context)
        attach(event: TranscriptEvent(title: "Soon standup", date: now.addingTimeInterval(3_600)),
               to: session, in: context)
        attach(item: TranscriptActionItem(task: "Follow up"), to: session, in: context)
        attach(person: TranscriptPerson(name: "Ana"), to: session, in: context)
        session.highlightsStatus = .ready

        let chips = ActionSuggestions.suggestions(for: session, includeContacts: true, now: now)

        #expect(chips.map(\.kind) == [.calendarEvent, .calendarEvent, .calendarEvent,
                                      .reminder, .contact])
        #expect(chips.map(\.detail).prefix(3) == ["Soon standup", "Late kickoff", "Undated retro"])
    }

    @Test func skipsPastEventsButKeepsPastDueOpenItems() throws {
        let (_, context, session) = try makeStore()
        attach(event: TranscriptEvent(title: "Already happened", date: now.addingTimeInterval(-3_600)),
               to: session, in: context)
        attach(item: TranscriptActionItem(task: "Still owed", dueDate: now.addingTimeInterval(-86_400)),
               to: session, in: context)
        session.highlightsStatus = .ready

        let chips = ActionSuggestions.suggestions(for: session, includeContacts: true, now: now)

        #expect(chips.map(\.kind) == [.reminder])
        #expect(chips.first?.detail == "Still owed")
    }

    @Test func doneActionItemsGetNoChip() throws {
        let (_, context, session) = try makeStore()
        let finished = TranscriptActionItem(task: "Already handled")
        finished.done = true
        attach(item: finished, to: session, in: context)
        attach(item: TranscriptActionItem(task: "Still open"), to: session, in: context)
        session.highlightsStatus = .ready

        let chips = ActionSuggestions.suggestions(for: session, includeContacts: true, now: now)

        #expect(chips.count == 1)
        #expect(chips.first?.detail == "Still open")
    }

    @Test func contactChipsAreExcludedWhereTheSurfaceDoesNotExist() throws {
        let (_, context, session) = try makeStore()
        attach(person: TranscriptPerson(name: "Sergio"), to: session, in: context)
        session.highlightsStatus = .ready

        #expect(ActionSuggestions.suggestions(for: session, includeContacts: true, now: now).count == 1)
        #expect(ActionSuggestions.suggestions(for: session, includeContacts: false, now: now).isEmpty)
    }

    // MARK: Dismissal

    @Test func dismissalRetiresJustThatChipAndPersists() throws {
        let (container, context, session) = try makeStore()
        let event = TranscriptEvent(title: "Design review", date: now.addingTimeInterval(3_600))
        attach(event: event, to: session, in: context)
        attach(item: TranscriptActionItem(task: "Send the deck"), to: session, in: context)
        session.highlightsStatus = .ready

        let before = ActionSuggestions.suggestions(for: session, includeContacts: true, now: now)
        #expect(before.count == 2)

        ActionSuggestions.dismiss(before[0].id, on: session, in: context)

        let after = ActionSuggestions.suggestions(for: session, includeContacts: true, now: now)
        #expect(after.map(\.id) == [before[1].id])

        // Persisted on the session — a fresh context over the same store still sees it.
        let sessionID = session.id
        let fresh = ModelContext(container)
        var descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID })
        descriptor.fetchLimit = 1
        let refetched = try #require(try fresh.fetch(descriptor).first)
        #expect(refetched.dismissedSuggestionIDs == ["event:\(event.id.uuidString)"])
    }

    @Test func dismissIsIdempotent() throws {
        let (_, context, session) = try makeStore()
        ActionSuggestions.dismiss("event:abc", on: session, in: context)
        ActionSuggestions.dismiss("event:abc", on: session, in: context)
        #expect(session.dismissedSuggestionIDs == ["event:abc"])
    }
}
