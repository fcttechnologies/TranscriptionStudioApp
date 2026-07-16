# Phase 3 — "the actions": device-verification & API grounding

Phase 3 ships **Flagship B's ecosystem surfaces** — turning an extracted transcript into *done things*
— on the Phase 2 spine (`TranscriptEvent` / `TranscriptActionItem` / `TranscriptPerson` and the
`AIToolSafety` "AI reads, user confirms writes" boundary):

- **EventKit** — draft-then-confirm Calendar events + Reminders from extracted events/action items,
  plus Siri-invocable App Intents that route through the confirm boundary.
- **Contacts** — speaker→contact mapping, auto-detected mention resolution, and Siri name resolution
  (bound/mentioned names folded into the Spotlight index).

The reusable pieces generalized into **FCTFoundation** (app-parameterized); the app supplies its own
mapping (see "What generalized vs stayed app-specific").

**Hard exclusion (respected):** the proactive suggestion-**chip** UX is *not* built. The detail view's
`// Phase 3 seam` is untouched. Phase 3 ships the actions + App Intents + a minimal, functional confirm
sheet — the taste-sensitive in-detail chip surface is a separate later pass.

## What CAN'T be verified in a build lane (and must be checked on device)

Permission prompts, a real Calendar/Reminders write, the system contact picker, and Siri phrasing run
only on a device (some also need Apple Intelligence for the upstream extraction). The lane verifies the
code path (documented API usage, deterministic logic unit-tested, clean iOS-sim + macOS builds). The
following are **on-device manual checks Fernando runs** — none is claimed runtime-verified.

### EventKit — Calendar (write-only) & Reminders
1. Open a transcript that extracted an **event** (e.g. "let's meet Tuesday at 2"). Trigger
   **"Add Meeting to Calendar"** (via Shortcuts/Siri, parameterized by the transcript). If the session
   has several events, confirm the **disambiguation** prompt appears; pick one.
2. The app opens to the **confirm sheet** — title + start/end are editable, notes carry attendees +
   "From transcript: …". Tap **Add to Calendar** → the **write-only** permission prompt appears the
   first time (`NSCalendarsWriteOnlyAccessUsageDescription`). Grant → the event lands in the default
   calendar. Confirm a success toast; confirm the event exists in Calendar.
3. **Nothing is written until Add** — dismiss the sheet without tapping Add and confirm no event is
   created.
4. Repeat for an **action item** via **"Add Action Item to Reminders"** → the reminders permission
   prompt (`NSRemindersFullAccessUsageDescription`), a due date + alarm when one resolved, saved to the
   default list.
5. **Deny** the permission once → confirm the failure toast is calm and points to Settings (no crash,
   no silent no-op).

### Contacts — speaker mapping, mentions, Siri name resolution
6. On a multi-speaker transcript, trigger **"Name Transcript Speakers"** (iOS). The naming sheet lists
   the diarized speakers; tap **Choose contact** → the **system contact picker** appears with **no
   Contacts permission prompt** (it runs out-of-process). Pick a contact → the speaker shows that name;
   confirm **Clear** removes it.
7. **Mentions section** — if Contacts read access is already granted, the sheet shows which extracted
   mentions are in your contacts (a checkmark + the contact name). Confirm opening the sheet **does not**
   trigger a contacts prompt when access is undetermined.
8. **Siri name resolution** — after binding a speaker (e.g. "Speaker 2" → "Sergio Ramos"), ask the
   library assistant / **"Ask a Transcript"** (no transcript chosen) a name question ("what did Sergio
   decide?"). Confirm it now resolves to that session even if the transcript text only said "Speaker 2"
   (the bound name is indexed as a Spotlight `keyword`). Note: reindex is async on bind — allow a moment.
9. **Contacts stays read-only** — the app never creates or edits a contact anywhere in this lane.

## Apple APIs grounded live via sosumi (not training memory)

Every Apple API below was confirmed against the live iOS/macOS 27 docs through `sosumi` while building.

| API | What was confirmed | Source |
|---|---|---|
| `EKEventStore.requestWriteOnlyAccessToEvents()` | `async throws -> Bool`; write-only = create events, **cannot read** existing; key `NSCalendarsWriteOnlyAccessUsageDescription` | eventkit/ekeventstore/requestwriteonlyaccesstoevents(completion:) · TN3152 |
| `EKEventStore.requestFullAccessToReminders()` | `async throws -> Bool`; **no write-only scope exists for reminders** — full is the minimal; key `NSRemindersFullAccessUsageDescription` | eventkit/ekeventstore/requestfullaccesstoreminders(completion:) |
| `EKEvent(eventStore:)` + `save(_:span:)` | `EKEvent(eventStore:)`; fields on `EKCalendarItem`; `func save(_ event: EKEvent, span: EKSpan) throws` | eventkit/ekevent · …/save(_:span:) |
| `EKReminder(eventStore:)` + `save(_:commit:)` | reminder creation; `func save(_ reminder: EKReminder, commit: Bool) throws`; `dueDateComponents` + `EKAlarm(absoluteDate:)` | eventkit/ekeventstore/save(_:commit:) |
| `defaultCalendarForNewEvents` / `defaultCalendarForNewReminders()` | the default destinations; readable to set on a new item under write access | eventkit/ekeventstore/defaultcalendarfornewevents · …fornewreminders() |
| `CNContactStore.requestAccess(for:)` | `async throws -> Bool` with `CNEntityType.contacts`; key `NSContactsUsageDescription` | contacts/cncontactstore/requestaccess(for:completionhandler:) |
| `CNAuthorizationStatus` | five states incl. `.limited` (iOS 18+ partial access) | contacts/cnauthorizationstatus |
| `CNContactStore.unifiedContacts(matching:keysToFetch:)` + `CNContact.predicateForContacts(matchingName:)` | name-predicate fetch, minimal name keys only | contacts/cncontactstore/unifiedcontacts(matching:keystofetch:) · cncontact/predicateforcontacts(matchingname:) |
| `AppIntent.requestChoice(between:dialog:)` + `IntentChoiceOption` | `-> IntentChoiceOption` (Equatable → map choice back by index) | appintents/appintent/requestchoice(between:dialog:) · appintents/intentchoiceoption |
| `@Property(indexingKey: \.keywords)` | valid Spotlight indexing key for `IndexedEntity` → CSSearchableItem `keywords` | (built on Phase 2's confirmed `IndexedEntity`/`CoreSpotlightSource` path) |

**Note — `CNContactPickerViewController` needs no Contacts permission** (it runs out of process and
returns only the tapped contact) — grounded, and why speaker binding is permission-free while mention
resolution (a store read) is not.

**Deploy floor is iOS/macOS 27**, so there is **no `#available` OS-version gating**. `#if os(...)` is
used only where a capability is genuinely one-platform (the iOS-only `CNContactPickerViewController`
naming sheet + `AssignSpeakersIntent`).

## What generalized into FCTFoundation vs stayed app-specific in TS

**Generalized (FCTFoundation `main`)** — app-parameterized, reusable (VA would use these):
- `FCTIntelligence.ConfirmableWrite` — the **write** side of "AI reads, user confirms writes": a
  two-phase `makeDraft()` (inert, reviewable) → `PendingWrite.confirm()` (the only path that commits)
  contract, so "never write without confirmation" is structural. `AIToolCapability` gains `.write`.
- `FCTContacts` (new module) — `ContactMatcher` (pure, framework-free name ranking with unambiguous
  best-match), `ContactResolving`/`ContactResolver`, and `ContactStoreResolver` (CNContactStore-backed,
  minimal read scope). Cross-app: speaker mapping, mention matching, Siri name resolution.

**App-specific (TranscriptionStudio, this branch)**:
- `EventDraftMapper` — `TranscriptEvent`→`CalendarDraft` / `TranscriptActionItem`→`ReminderDraft`
  (deterministic; default duration, next-hour fallback, attribution) — unit-tested.
- `EventKitBuilder` — draft→`EKEvent`/`EKReminder` field mapping — unit-tested.
- `CalendarWriteAction` / `ReminderWriteAction` — `ConfirmableWrite` conformances committing with the
  minimal scope; the confirm sheets + `AddEventToCalendarIntent` / `AddActionItemReminderIntent`.
- `SpeakerAssignment` `@Model` + `SpeakerAssignmentStore`; `SessionPeople` (the indexed name set);
  `MentionResolver` (TS names → contacts); `TranscriptSessionEntity.people` (`\.keywords`);
  `SpeakerAssignmentSheet` + `AssignSpeakersIntent` (iOS).

## Build + test results (this lane)

- **iOS** (Debug, dedicated `TS-Phase3` iPhone 17 Pro / iOS 27 sim, `CODE_SIGNING_ALLOWED=NO`):
  **BUILD SUCCEEDED, 0 warnings**.
- **macOS** (Debug, `platform=macOS`, `CODE_SIGNING_ALLOWED=NO`): **BUILD SUCCEEDED, 0 warnings**;
  `swift build` clean.
- **FCTFoundation** suite (incl. new `ConfirmableWriteTests`, `FCTContactsTests`): **all green**.
- **TranscriptionStudio** suite (`TS_SKIP_MODEL_TESTS=1 swift test`, incl. `EcosystemActionsTests`,
  `ContactsFeatureTests`): **368 tests, all green**.
