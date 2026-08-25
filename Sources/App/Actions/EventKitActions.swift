import Foundation
import EventKit
import FCTIntelligence

/// The Calendar write, as the app-side of the generalized ``ConfirmableWrite`` boundary. It carries an
/// inert ``CalendarDraft`` (already mapped from a `TranscriptEvent` on the main actor, so nothing
/// non-`Sendable` is captured); `commit` requests the **minimal write-only** calendar scope and saves
/// the event to the user's default calendar. Nothing is written until the confirm sheet calls
/// `commit` with the reviewed (possibly edited) draft.
struct CalendarWriteAction: ConfirmableWrite {
    typealias Output = Void

    private let initialDraft: CalendarDraft

    init(draft: CalendarDraft) {
        self.initialDraft = draft
    }

    func makeDraft() -> CalendarDraft { initialDraft }

    func commit(_ draft: CalendarDraft) async throws {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestWriteOnlyAccessToEvents()
        } catch {
            throw EventKitWriteError.accessDenied
        }
        guard granted else { throw EventKitWriteError.accessDenied }
        let event = EventKitBuilder.makeEvent(from: draft, in: store)
        guard event.calendar != nil else { throw EventKitWriteError.noDestination }
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw EventKitWriteError.saveFailed
        }
    }
}

/// The Reminders write. Reminders have no write-only scope, so this requests the minimal available —
/// full reminders access — then saves an `EKReminder` (with a due date + alarm when one resolved) to
/// the default list. Same draft-then-confirm discipline as the calendar write.
struct ReminderWriteAction: ConfirmableWrite {
    typealias Output = Void

    private let initialDraft: ReminderDraft

    init(draft: ReminderDraft) {
        self.initialDraft = draft
    }

    func makeDraft() -> ReminderDraft { initialDraft }

    func commit(_ draft: ReminderDraft) async throws {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw EventKitWriteError.accessDenied
        }
        guard granted else { throw EventKitWriteError.accessDenied }
        let reminder = EventKitBuilder.makeReminder(from: draft, in: store)
        guard reminder.calendar != nil else { throw EventKitWriteError.noDestination }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitWriteError.saveFailed
        }
    }
}
