import Testing
import Foundation
import EventKit
import SwiftData
@testable import TranscriptionStudio

/// The deterministic half of the EventKit lane: the `TranscriptEvent`/`TranscriptActionItem` → draft
/// mapping and the draft → `EKEvent`/`EKReminder` field mapping — both exercised without a live store
/// or any permission (constructing EventKit objects needs neither).
struct EcosystemActionsTests {

    private let reference = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 9))!

    // MARK: - EventDraftMapper (calendar)

    @Test func calendarDraftUsesResolvedDateAndOneHourDefaultDuration() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 14))!
        let draft = EventDraftMapper.calendarDraft(
            title: "Design review", date: date, dateText: "next Wednesday at 2",
            attendees: ["Ana", "Sergio"], sessionTitle: "Budget meeting")

        #expect(draft.title == "Design review")
        #expect(draft.startDate == date)
        #expect(draft.endDate == date.addingTimeInterval(3600))
        #expect(draft.notes.contains("Attendees: Ana, Sergio"))
        #expect(draft.notes.contains("From transcript: Budget meeting"))
        // A resolved date means we don't repeat the spoken phrase in the notes.
        #expect(!draft.notes.contains("Mentioned time"))
    }

    @Test func calendarDraftWithoutADateDefaultsToNextHourAndKeepsThePhrase() {
        let draft = EventDraftMapper.calendarDraft(
            title: "Kickoff", date: nil, dateText: "sometime next week",
            attendees: [], sessionTitle: "Standup", now: reference)

        // 9:00 reference → next whole hour is 10:00.
        #expect(draft.startDate == Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 10))!)
        #expect(draft.notes.contains("Mentioned time: sometime next week"))
    }

    @Test func attributionFallsBackWhenSessionUntitled() {
        let draft = EventDraftMapper.calendarDraft(
            title: "Sync", date: reference, dateText: "", attendees: [], sessionTitle: "   ")
        #expect(draft.notes.contains("From a Transcription Studio recording"))
    }

    @Test func nextHourRoundsUpStrictly() {
        let onTheHour = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 15))!
        #expect(EventDraftMapper.nextHour(after: onTheHour)
                == Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 16))!)
    }

    // MARK: - EventDraftMapper (reminders)

    @Test func reminderDraftCarriesOwnerAndResolvedDueDate() {
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 17))!
        let draft = EventDraftMapper.reminderDraft(
            task: "Send the deck", owner: "Sergio", dueDate: due, dueDateText: "by Friday",
            sessionTitle: "Budget meeting")

        #expect(draft.title == "Send the deck")
        #expect(draft.dueDate == due)
        #expect(draft.notes.contains("Owner: Sergio"))
        // A resolved date means the spoken phrase isn't duplicated.
        #expect(!draft.notes.contains("Mentioned due"))
    }

    @Test func reminderDraftKeepsUnresolvedDuePhrase() {
        let draft = EventDraftMapper.reminderDraft(
            task: "Follow up", owner: nil, dueDate: nil, dueDateText: "end of the sprint",
            sessionTitle: "Retro")
        #expect(draft.dueDate == nil)
        #expect(draft.notes.contains("Mentioned due: end of the sprint"))
        #expect(!draft.notes.contains("Owner:"))
    }

    // MARK: - EventKitBuilder field mapping

    @Test func buildsEventFieldsFromDraft() {
        let store = EKEventStore()
        let start = reference
        let draft = CalendarDraft(title: "Sync", startDate: start,
                                  endDate: start.addingTimeInterval(1800), notes: "hello")
        let event = EventKitBuilder.makeEvent(from: draft, in: store)

        #expect(event.title == "Sync")
        #expect(event.startDate == start)
        #expect(event.endDate == start.addingTimeInterval(1800))
        #expect(event.notes == "hello")
    }

    @Test func buildsReminderWithDueDateAndAlarm() {
        let store = EKEventStore()
        let due = reference
        let reminder = EventKitBuilder.makeReminder(
            from: ReminderDraft(title: "Ping", notes: "n", dueDate: due), in: store)

        #expect(reminder.title == "Ping")
        #expect(reminder.notes == "n")
        let comps = reminder.dueDateComponents
        #expect(comps?.year == 2026 && comps?.month == 7 && comps?.day == 20)
        #expect(reminder.hasAlarms)
    }

    @Test func buildsReminderWithoutDueDateHasNoAlarm() {
        let store = EKEventStore()
        let reminder = EventKitBuilder.makeReminder(
            from: ReminderDraft(title: "Someday", notes: "", dueDate: nil), in: store)
        #expect(reminder.dueDateComponents == nil)
        #expect(!reminder.hasAlarms)
    }

    // MARK: - The @Model convenience overloads

    @Test @MainActor func modelOverloadsReadTheStoredFields() throws {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Q3 planning", kind: .roomRecording)
        context.insert(session)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 11))!
        let event = TranscriptEvent(title: "Roadmap", dateText: "Aug 1", date: date, attendees: ["Ana"])
        event.session = session
        context.insert(event)
        let item = TranscriptActionItem(task: "Draft doc", owner: "Me", dueDateText: "Friday", dueDate: date)
        item.session = session
        context.insert(item)

        let calDraft = EventDraftMapper.calendarDraft(for: event, sessionTitle: session.title)
        #expect(calDraft.title == "Roadmap")
        #expect(calDraft.startDate == date)
        #expect(calDraft.notes.contains("Attendees: Ana"))

        let remDraft = EventDraftMapper.reminderDraft(for: item, sessionTitle: session.title)
        #expect(remDraft.title == "Draft doc")
        #expect(remDraft.dueDate == date)
        #expect(remDraft.notes.contains("From transcript: Q3 planning"))
    }
}
