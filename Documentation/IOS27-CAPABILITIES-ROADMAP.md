# iOS 27 Capabilities Roadmap — Transcription Studio

What it takes to make Transcription Studio the best transcription app on the iOS 27 launch.
Grounded in `~/Jarvis/database/research/wwdc26/ios-27-capabilities.md`, the current
`TranscriptionKit` source, VillainArc's shipped `AskVillainArcAssistant` (the Siri-Q&A
flagship's direct reference), and PersonalContext's donation/entity patterns. Planning only —
no code changes land from this document.

## Two co-flagships, one substrate

TS's iOS 27 story has **two headline capabilities**, not one:

- **Flagship A — Siri semantic Q&A**: "what did Sergio and I decide at the last meeting?"
  answered from the whole transcript library, hands-free.
- **Flagship B — proactive ecosystem intelligence**: the app doesn't just *answer* questions
  about a transcript, it *acts* on one — extracting decisions, action items, events, people,
  and places, then proactively offering to turn them into a Calendar event, a Reminder, a
  saved Contact — turning a conversation into done things, not just searchable text.

Both flagships share one substrate: a **structured extraction pass** over every transcript
(Foundation Models guided generation). That extraction is what the Q&A assistant retrieves
against *and* what the proactive suggestions are built from — build it once, and both
flagships get stronger together. This is why Flagship B's extraction layer is ranked
immediately behind Flagship A in the build sequence: it is the dependency both headline
capabilities share.

## Where TS already stands (read this before the capability list)

TS is further along the iOS 27 curve than a typical app already:

- **Deploy target is already iOS 27 on both platforms** (`project.yml`, both targets:
  `deploymentTarget: "27.0"`), forced by the Sortformer diarizer being a Core AI (`.aimodel`)
  model — a WWDC26/iOS-27-only framework. This means **every API in this document is
  already available with no `#available` OS-version gate** — the floor is already the
  ceiling. The only gating left is *capability* gating (Apple Intelligence eligibility/
  enablement, device Neural Engine class, permission grants), which is orthogonal to OS
  version and already the pattern `SessionIntelligence`/`AskVillainArcAssistant` use.
- **App Intents are already extensive**: 12+ intents (`StartRecordingIntent`,
  `StopRecordingIntent`, `GetRecordingStatusIntent`, `TranscribeFileIntent`,
  `TranscribeLinkIntent` [Mac], `SearchTranscriptsIntent`, `GetLatestTranscriptIntent`,
  `AskTranscriptIntent`, `SummarizeTranscriptIntent`, `ExportTranscriptIntent`,
  `OpenTranscriptIntent`, `OpenLibraryIntent`, `OpenInspectorIntent`, `RenameTranscriptIntent`,
  `DeleteTranscriptIntent`, `PlayTranscriptIntent`, `PausePlaybackIntent`), a 9-shortcut
  (iOS) / 10-shortcut (Mac) `AppShortcutsProvider` at the system cap, and real UI-action
  donations (`TranscriptionIntentDonations`).
- **`TranscriptSessionEntity` is already `IndexedEntity`**, donated to a stable, app-owned
  *named* Core Spotlight index (`TranscriptSpotlightIndex`, index name
  `"TranscriptionStudioSessions"`) with `@Property(indexingKey:)` on title/date/kind/duration
  and a 280-char transcript preview, indexed/deindexed/reindexed on every mutation.
- **Foundation Models is already wired** (`SessionIntelligence`): on-device summarize + ask,
  availability-gated, degrade-gracefully everywhere, with `AskTranscriptIntent` /
  `SummarizeTranscriptIntent` as thin App Intent adapters over the same use case (no
  parallel code path) — the exact shape `apple-intelligence/foundation-models` recommends.
- **What's *not* built yet is precisely both flagships.** `AskTranscriptIntent` answers a
  question about **one transcript at a time** — there is no cross-library semantic
  retrieval. And there is **no extraction layer at all** — no structured decisions/action
  items/events/people/places, and consequently **no EventKit, no Contacts auto-detection,
  and no proactive suggestion surface** anywhere in the app. Everything in this document
  past Flagship A is either that missing extraction substrate or something built on top of it.

So this roadmap is not "adopt iOS 27" (mostly done) — it's "close the specific gaps between
a strong iOS-27-native app and the best transcription app of the generation," headlined by
the two capabilities that change what people say to it and what it does for them.

---

## 1. FLAGSHIP A — Siri semantic Q&A over the whole transcript library

**What it is.** A "Spotlight Search Tool"-backed `LanguageModelSession` that can search
*across every saved transcript* (not just one) and answer from what it finds — "hey Siri,
what did Sergio and I decide at the last meeting?" resolves to *which* session (semantic
match on "Sergio" + "meeting" + recency), then answers *from* its content, in one Siri turn.

**Direct reference: `AskVillainArcAssistant`** (`~/Projects/VillainArc/VillainArc/Data/Services/AI/Assistant/AskVillainArcAssistant.swift`).
Its shape is exactly right for TS and should be ported, not reinvented:

```swift
enum AskVillainArcAssistant {
    static var availability: Availability { /* iOS 27 + SystemLanguageModel.default.availability gate */ }
    static var instructions: String { /* strict read-only, private-data-only system prompt */ }
    static func ask(_ question: String) async -> Result<String, AskError> {
        let tools = AIToolSafetyPolicy.vettedSpotlightTools([makeSpotlightTool()])
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        // ...
    }
    static func makeSpotlightTool() -> SpotlightSearchTool {
        SpotlightSearchTool(configuration: .init(sources: [.coreSpotlight]))
    }
}
```

Paired with `AIToolSafetyPolicy` (`~/Projects/VillainArc/VillainArc/Data/Services/AI/Shared/AIToolSafety.swift`):
a `SafeTool` marker protocol + `AIToolCapability.readOnly`, a static allowlist, and a
precondition-enforced "AI reads, user confirms writes" boundary — the system Spotlight tool
is vetted as read-only at the type level, with a unit test (`AIToolSafetyTests`) that fails
the build if a write-capable or unregistered tool is ever attached to a session. **TS should
adopt this exact pattern**, not a looser one — an assistant that can read every transcript in
the library is exactly the kind of surface the agentic-safety playbook (below) is written for,
and it becomes even more important once Flagship B adds write-capable EventKit/Contacts
actions elsewhere in the app: the read-only Q&A session and the write-capable suggestion
flows must stay on opposite sides of that boundary, never merged into one tool-calling loop.

**The one real technical gap to close: named-index scoping + full-text hydration.**
`AskVillainArcAssistant`/VillainArc index into `CSSearchableIndex.default()` (the system
default index). TS deliberately does **not** — `TranscriptSpotlightIndex` donates into a
**named** index (`"TranscriptionStudioSessions"`) specifically because a named index carries
a data-protection class (see the code comment: "never the system default — only a named
index carries a data-protection class"). `SpotlightSearchTool` needs to be pointed at *that*
named index, not the default. Per the WWDC26 session and current third-party writeups, this
is exactly what the custom-configuration path is for:

```swift
let source = CoreSpotlightSource(
    searchableIndexDelegate: delegate,      // backed by CSSearchableIndex(name: "TranscriptionStudioSessions")
    fetchAttributes: [.title, .contentDescription, .contentCreationDate, .keywords]
)
let searchTool = SpotlightSearchTool(configuration: .init(source: source))
```

The delegate's `searchableItems(forIdentifiers:)` is also the **full-item recovery** hook TS
needs regardless: today's indexed `textPreview` is truncated to 280 characters (deliberately
compact, matching the spotlight-indexing generator's guidance to keep the on-disk index
small). The model answering "what did Sergio and I decide" needs much more than 280
characters of context. The delegate should fetch the *full* `fullText` for the requested
session id(s) at query time (bounded the same way `SessionIntelligence.trimmedForContext`
already bounds single-session Q&A — reuse that helper) and attach it as
`contentDescription`/`textContent` on the recovered `CSSearchableItem`, never inflating the
persisted index itself. This is the "index for two consumers" split the spotlight-indexing
skill calls out explicitly: compact metadata for ordinary search UI, hydrated full text only
when the model's tool call actually needs it.

**Everything else is already in place**: the named index exists and is kept current
(index/deindex/reindex on every session mutation), `TranscriptSessionEntity` is already
`IndexedEntity`, and `SessionIntelligence`'s availability-gate/error-mapping pattern carries
over unchanged. This is *substantially* a wiring + safety-boundary task, not a from-scratch
build — which is exactly why it should ship as `AskTranscriptStudioIntent` (a new, separate
intent from `AskTranscriptIntent`) or an upgrade to `AskTranscriptIntent` when no `session`
parameter is given (today that case falls back to "latest transcript"; it should instead
trigger library-wide Spotlight RAG — a strictly better default that still degrades to the
current single-session behavior when a `session` parameter is explicitly passed).

**Also needed:**
- **Query tokens for multi-call answers.** A single question may cause the model to call the
  Spotlight tool more than once (e.g. resolve "Sergio" as a person mention, then "last
  meeting" as a recency filter). Use the reply's `queryToken` to keep result batches distinct
  if/when the UI surfaces search-result lists.
- **Extraction-enriched retrieval.** Once Flagship B's extraction layer exists, its structured
  `decisions`/`people`/`events` should be folded into the same index (see capability 2) — a
  semantic query against a `decisions` list retrieves far better than against raw transcript
  prose. Flagship A should be built to *consume* that enrichment once it lands, not treat
  extraction as unrelated.
- **Contact resolution for "Sergio."** See capability 4 (Contacts) — without speaker→contact
  binding, "Sergio" only matches if the name was literally spoken in the transcript (which it
  very often is — "so Sergio, what do you think" — so this works today even before Contacts
  binding ships, and gets meaningfully more precise once it does, especially when there's
  ambiguity between two people with the same first name).
- **Evals.** Per the Evaluations framework, this needs trajectory + retrieval-coverage evals
  (expected session IDs found, not just "answer sounds plausible") before it ships as a
  headline capability — mirroring `AskVillainArcAssistantTests`.

**User value:** the single most differentiating *retrieval* capability on the list — "ask my
meetings what happened" with zero manual scrolling/search, spoken and hands-free.

**Effort:** L (multi-day: named-index delegate + full-text recovery, the vetted-tool safety
boundary, the new/upgraded intent, evals, on-device testing across transcript-library sizes).
**TS-applicability:** High. **Deploy-target impact:** none — already on iOS 27.

---

## 2. FLAGSHIP B — Foundation Models extraction layer

**What it is.** A structured-extraction pass over every completed transcript, using
Foundation Models **guided generation** (`@Generable`/`@Guide`), pulling out decisions,
action items, events/meetings/deadlines, people, and places as *typed* data — not more prose.
This is the substrate for everything else in this section: without it, there is nothing for
EventKit to prefill, nothing for Contacts auto-detection to match against, and nothing for
the proactive suggestion chips to display. It also directly strengthens Flagship A, since
semantic search against a structured `decisions: [String]` list retrieves far better than
against raw transcript text.

**Shape:**

```swift
@Generable(description: "Structured highlights extracted from a transcript")
struct SessionHighlights: Sendable {
    @Guide(description: "Key decisions made, one concise sentence each")
    var decisions: [String]

    @Guide(description: "Action items or tasks someone committed to")
    var actionItems: [ExtractedActionItem]

    @Guide(description: "Meetings, events, or deadlines mentioned with a date or time reference")
    var events: [ExtractedEvent]

    @Guide(description: "People mentioned by name or speaking in the conversation")
    var people: [String]

    @Guide(description: "Places or locations mentioned")
    var places: [String]
}

@Generable
struct ExtractedActionItem: Sendable {
    var task: String
    @Guide(description: "Who is responsible, if stated; otherwise omitted")
    var owner: String?
    @Guide(description: "The due date/time exactly as stated in the conversation, e.g. 'next Tuesday' or 'by Friday'")
    var dueDateText: String?
}

@Generable
struct ExtractedEvent: Sendable {
    var title: String
    @Guide(description: "The date/time exactly as stated in the conversation")
    var dateText: String
    var attendees: [String]
}
```

**Relative-date resolution is the fiddly part.** People say "next Tuesday" and "in two
weeks," not ISO 8601. The extraction prompt should include *today's date* (and the session's
`createdAt`, since a recording may be discussed and reviewed days apart) in its instructions
— "Resolve relative dates against this reference date" — so `dueDateText`/`dateText` can be
turned into a concrete `Date` deterministically downstream (a plain date-parsing pass, e.g.
`NSDataDetector` or `DateComponents` reconstruction, not a second model call) before EventKit
ever sees it. Keep the model's job as *extraction* and the date-math as ordinary, testable
Swift — don't ask the model to do arithmetic it isn't built for.

**Storage: real SwiftData models, not a Codable-attribute blob.** The capabilities doc is
explicit that Codable attributes are the wrong tool for "app-owned types that should be
queryable, sortable, migrated, or related" — and action items are exactly that: a future
"show me all my open action items across every meeting" is itself a plausible Siri feature,
which needs `ActionItem`/`ExtractedEvent` as real `@Model` types (with a `done: Bool`,
`session: TranscriptSession?` relationship, `#Index` on due date) — not opaque encoded data
SwiftData can't query. Reserve Codable attributes for genuinely framework-owned types with no
query need (e.g. a raw `CLLocationCoordinate2D` under capability 9, Location).

**Scheduling: background, non-blocking, after save.** Run the extraction pass as a
lower-priority background `Task` immediately after a session finishes (`TranscriptionJob`
reaches `.done`), not inline before the session can be saved — extraction latency should
never gate seeing the transcript. Expose a lightweight `highlightsStatus` (`.pending` /
`.ready` / `.unavailable`) on the session so the detail view can show suggestion chips only
once ready, and degrade silently (no highlights, no chips — never an error state) when Apple
Intelligence isn't available, matching `SessionIntelligence`'s existing degrade-gracefully
posture.

**User value:** turns transcript review from "read/skim the text" into "here's what actually
needs to happen" — the substrate the rest of Flagship B is built on.

**Effort:** L (schema design, background scheduling + status surfacing, the SwiftData model
addition, relative-date resolution, and evals — extraction quality is exactly the kind of
thing that needs the Evaluations framework's sample-based measurement, not eyeballing).
**TS-applicability:** High — this is the dependency both flagships share.
**Deploy-target impact:** none.

---

## 3. EventKit — Calendar + Reminders proactive actions

**What it is.** When extraction (capability 2) surfaces an event/meeting/deadline or an
action item, offer to turn it into a real `EKEvent` or `EKReminder` — prefilled with the
extracted title, date, and attendees — via both an in-app suggestion (capability 5) and a
Siri/Shortcuts App Intent.

**How it applies:**
- **Draft, then confirm — never silently write.** Use `EventKitUI`'s `EKEventEditViewController`
  (or the Reminders equivalent) to show the *system's own* creation sheet, prefilled from the
  extracted `ExtractedEvent`/`ExtractedActionItem`, so the user reviews and taps Add — the app
  never calls `EKEventStore.save` directly from a suggestion tap. This is the same
  "draft-then-commit" discipline `apple-intelligence/foundation-models` and the agentic-safety
  guidance both call out for any AI-sourced write: a Calendar/Reminders write is exactly the
  kind of externally-visible, side-effecting action that must never happen without the user
  seeing what's being written.
- **Request the minimally-scoped permission.** TS never needs to *read* the user's existing
  calendar/reminders — only add to it. Request write-only access
  (`EKEventStore.requestWriteOnlyAccessToEvents`), not full read/write access
  (`requestFullAccessToEvents`), and phrase `NSCalendarsUsageDescription` /
  `NSRemindersUsageDescription` accordingly (matching TS's existing privacy-forward posture —
  see the mic-usage strings already in `project.yml`). Over-asking permission here would be a
  real inconsistency with an app whose whole pitch is "nothing leaves your device" restraint.
- **The App Intent side.** `AddMeetingToCalendarIntent` / `AddActionReminderIntent` —
  "add the meeting from this transcript to my calendar" via Siri/Shortcuts, parameterized by a
  `TranscriptSessionEntity` (and, when a session has multiple extracted events/action items, a
  `requestChoice` disambiguation the same way `DeleteTranscriptIntent` already does). These
  should still open `EventKitUI` in the foreground for the actual add — a voice-triggered
  Calendar write with zero visual confirmation is a worse pattern than the in-app suggestion,
  not a better one, even though it's technically possible to do headlessly.

**User value:** the biggest "wow" beyond Q&A — "the meeting decided X, and it's already a
Calendar event" without ever opening Calendar. This is the literal turn-conversations-into-
actions capability Fernando is describing, and it is what makes Flagship B *felt*, not just
architecturally present.

**Effort:** M (EventKitUI integration for the review sheet, the write-only permission flow,
the two App Intents with disambiguation, wiring the resolved dates from capability 2's
date-text through to real `EKEvent`/`EKReminder` fields). **Depends on capability 2**
(extraction) existing first — there's nothing to prefill otherwise.
**TS-applicability:** High. **Deploy-target impact:** none — EventKit/EventKitUI are long-
stable frameworks with no iOS 27 gate; write-only access has been available for several OS
generations, safely inside the iOS 27 floor regardless.

---

## 4. Contacts — speaker mapping, auto-detection, and Siri name resolution

**What it is.** Three related capabilities under one framework: (a) let the user bind a
diarized speaker slot to a real Contacts entry, (b) auto-detect people *mentioned* (not just
speaking) via extraction and offer to save/link them, and (c) let the Siri Q&A assistant
(Flagship A) resolve a spoken name like "Sergio" against the user's actual Contacts when
answering.

**How it applies:**
- **(a) Speaker → contact binding.** `StoredSegment.speakerSlot` (-2 unknown / -1 me / 0–3
  diarized) has no name today — the UI shows "Speaker 1/2/3," and the fusion pipeline
  (`TranscriptFuser`/`SpeakerID`) has no concept of a person, only a slot. Add a per-session
  mapping from `SpeakerID.speaker(Int)` → a stored contact identifier + display name (a real
  small `@Model`, e.g. `SpeakerAssignment`, not a Codable blob — it's queryable, per-session
  data), surfaced in the detail view's per-speaker label (feeding the Voice-Memos-style
  speaker grouping already spec'd in `DETAIL-REDESIGN.md`) and folded into `fullText`/the
  Spotlight index's `keywords` so a name search ("what did Sergio say") matches by name.
- **(b) Auto-detected mentions.** Capability 2's `people: [String]` extraction surfaces names
  that were *mentioned*, whether or not that person was a speaker. Cross-reference each
  against `CNContactStore` by fuzzy name match: an exact/near match becomes a lightweight
  "this is [existing contact]" confirmation (folded into the proactive suggestion chips,
  capability 5); no match becomes a "Save as new contact" offer. Both are draft-then-confirm,
  same discipline as EventKit — the app never silently creates or links a contact.
- **(c) Siri name resolution.** The capabilities doc calls out Spotlight Search Tool "contact
  resolvers" as the mechanism for resolving "me," "Sergio," "my sister" against index
  metadata during a search. Once (a) and (b) exist, wire the resolved contact identifiers into
  the indexed content so Flagship A's assistant can disambiguate two people who share a first
  name, or confirm which "Sergio" (a contact ID, not just a string) a query means.

**User value:** directly makes both flagships' headline examples literal — "Sergio," not
"Speaker 2," everywhere: in the transcript UI, in what Siri can search on, and in who gets a
contact suggestion. This is the connective tissue between Flagship A and Flagship B.

**Effort:** M (Contacts permission + picker UI for (a); fuzzy-match + suggestion wiring for
(b), which depends on capability 2; the index/resolver wiring for (c), which depends on
Flagship A's Spotlight tool existing). **TS-applicability:** High.
**Deploy-target impact:** none; `CNContactStore` needs its own Info.plist usage string
(`NSContactsUsageDescription`), not an OS-version gate.

---

## 5. Proactive suggestion UX

**What it is.** The UI shape that makes extraction (capability 2) *felt*: elegant, dismissible
suggestion chips in the transcript detail view — "Add to Calendar," "Set Reminder," "Save
Contact" — appearing once a session's `SessionHighlights` are ready, each opening the relevant
system sheet (EventKitUI, the Contacts picker) on tap.

**How it applies.** `DETAIL-REDESIGN.md` already establishes `SessionDetailView`'s visual
language (karaoke playhead, conditional speaker grouping, playback bar, sparkles/ellipsis
actions, the circular `xmark` close pattern). Suggestion chips are a new component in that
same surface: a horizontally-scrollable chip row (or a dedicated "Suggested" section) below
the header, populated once `highlightsStatus == .ready`. Each chip pairs an SF Symbol + a
short label drawn from the extracted item (e.g. a calendar-badge icon + "Add to Calendar —
Tue budget review"); tapping opens the matching draft-then-confirm sheet from capability 3 or
4; a small `x` dismisses it, and dismissal is remembered per-item (a `dismissedSuggestionIDs`
set, not a session-wide toggle) so a dismissed suggestion doesn't resurface on next visit.

**This needs the `taste` skill's anti-slop checklist explicitly**, more than most items on
this list — a suggestion-chip row is exactly the UI shape that turns into visual noise or a
generic "AI feature" upsell banner if not deliberately restrained. The bar is the same one
`DETAIL-REDESIGN.md` sets for the rest of the view: Apple Music / Voice Memos-level restraint,
not a notification-badge-covered feature-flag surface. Build a reference board before
implementing, per the `taste` skill's method, rather than freehand a "smart suggestions" card.

**User value:** this is the entire delivery mechanism for Flagship B. Extraction without this
is a backend capability nobody sees; extraction *with* this is "the app noticed the meeting
and offered to put it on my calendar" — the product experience, not just the plumbing.

**Effort:** M (new SwiftUI component + per-item dismissal state + wiring to the EventKit/
Contacts sheets from capabilities 3–4; a real visual-design pass against the taste checklist,
since this is a brand-new UI pattern with no existing TS precedent to match).
**TS-applicability:** High — without this, capability 2's extraction has no user-facing payoff.
**Deploy-target impact:** none.

---

## 6. Full ecosystem mapping

The complete map from what a transcript can contain to what the system can do with it — every
row already has a home in a section above; this is the at-a-glance spine of the whole
ecosystem-integration pillar.

| Extracted from the transcript | System integration | Mechanism | Where |
|---|---|---|---|
| Decisions | Siri Q&A / search | Indexed into Spotlight `contentDescription`/`keywords`, retrieved by `SpotlightSearchTool` | §1 Flagship A, §2 Flagship B |
| Action items (task + owner + due date) | Reminders | `EKReminder` via `EventKitUI`, draft-then-confirm | §3 EventKit |
| Meetings / events / deadlines | Calendar | `EKEvent` via `EventKitUI`, draft-then-confirm | §3 EventKit |
| People mentioned or speaking | Contacts | Speaker→contact binding + auto-detected-mention matching; feeds Siri person-resolution | §4 Contacts |
| Places / locations mentioned | Maps / location context | Resolved via `CLGeocoder`; a Maps deep-link chip alongside recording-location metadata | §11 Location |
| The transcript as a whole | Siri / Spotlight / Shortcuts | `IndexedEntity` + `SpotlightSearchTool` RAG | §1 Flagship A |
| Live audio / playback | Control Center, Lock Screen, Dynamic Island | `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` + ActivityKit (already spec'd) | `DETAIL-REDESIGN.md` (cross-reference, not new) |
| A file/meeting transcription job in progress | Dynamic Island, Lock Screen | ActivityKit Live Activity + `BGContinuedProcessingTask` | §7 Background GPU |

Reading the table top to bottom is reading the product pitch: every kind of thing a
conversation contains has a named, concrete system surface it becomes — not a generic "AI
summary" but Calendar, Reminders, Contacts, Maps, Siri, Spotlight, Control Center, and the
Lock Screen, each doing the one thing it's already good at.

---

## 7. App Intents / App Schemas — the rest of the Siri integration spine

**What it is.** Beyond the intents TS already ships (and the two new EventKit intents from
capability 3), the newer App Intents surface: `LongRunningIntent`/`CancellableIntent` for the
pipeline's real long-running work, `RelevantEntities` donation, on-screen entity annotations,
and `OwnershipProvidingEntity` for exports/shares.

**How it applies, concretely:**
- **`LongRunningIntent` + `CancellableIntent` for `TranscribeFileIntent`/`TranscribeLinkIntent`.**
  Today these are `.foreground` intents that open the app and let the existing `JobStore`
  pipeline run; a long file/URL transcription is exactly the "uploads, sync, ML/inference"
  case the capability doc calls out for `LongRunningIntent`, and `TranscriptionJob.cancel()`
  already exists — it's just not reachable as a Siri/Shortcuts cancellation today.
- **`RelevantEntities` for the active/last-opened session.** When a session is open in the
  detail view, donate it as relevant so "summarize this" / "ask about this" resolve without
  disambiguation — contextual relevance (this lever) is distinct from Spotlight indexing
  (Flagship A), per the capabilities doc's own framing.
- **On-screen entity annotation** (`.userActivity` + `EntityIdentifier`) on `SessionDetailView`
  so "summarize this" said while the detail view is open resolves to the visible session with
  zero parameters — the natural voice-only companion to both flagships.
- **`OwnershipProvidingEntity`** on `ExportTranscriptIntent`'s output when a transcript is
  shared/exported outside the app — currently `ExportTranscriptIntent` returns an `IntentFile`
  with no ownership/confirmation signal.

**User value:** fewer follow-up questions from Siri, a real cancel path for long jobs from
voice/Shortcuts, and "summarize this" working with zero parameters while looking at a
transcript.

**Effort:** M (four independent small-to-medium changes, each testable in isolation).
**TS-applicability:** Medium-High. **Deploy-target impact:** none.

---

## 8. Foundation Models — beyond extraction

**What it is.** Once capability 2's extraction layer exists, two further Foundation Models
upgrades are worth doing on their own merits: removing the on-device context ceiling for long
transcripts, and unifying the growing number of model "verbs" into one coherent session shape.

**How it applies:**
- **PCC escalation for long transcripts.** `SessionIntelligence.trimmedForContext` currently
  hard-truncates at ~12k characters to stay inside the on-device context window. A
  `PrivateCloudComputeLanguageModel` fallback (larger context, same `LanguageModelSession`
  API) removes that ceiling for long meetings — check `contextSize` at runtime rather than
  hardcoding, and escalate only when the transcript actually exceeds the on-device budget
  (cost/latency-aware, not default-on).
- **Dynamic Profiles once there are 3+ verbs.** By the time extraction (capability 2), ask,
  and summarize all exist, there are three model "verbs" running as separate fresh-session
  call sites. A `LanguageModelSession.DynamicProfile` switching instructions per verb while
  sharing model/tool-calling-mode configuration is the architecturally cleaner shape at that
  point — not before; two verbs don't justify the refactor.
- **Image input**: not applicable — TS has no photo/image intake path today. Skip unless a
  future feature (e.g. importing a whiteboard photo alongside a recording) is scoped.

**User value:** no silent truncation on long recordings; cleaner internal architecture as the
number of AI verbs grows.

**Effort:** PCC escalation: M. Dynamic Profiles refactor: S, but sequenced after capability 2.
**TS-applicability:** Medium-High. **Deploy-target impact:** none.

---

## 9. Background GPU / background inference

**What it is.** Running the transcription pipeline's GPU/ANE work (WhisperKit ASR +
Sortformer diarization, both Core AI/CoreML-backed) when the app is backgrounded, instead of
today's foreground-only execution. The concrete API is **`BGContinuedProcessingTask`**
(introduced iOS 26, so already available given the iOS 27 floor): it lets an app that started
compute-heavy work in the foreground *continue* it briefly in the background, with **mandatory
`Progress` reporting** and system-driven UI (a Live Activity is the expected/idiomatic
pairing — `NSSupportsLiveActivitiesFrequent`), and supports specifying compute units
(CPU/GPU/Neural Engine) for the continued work.

**How it applies.** Today: `TranscriptionJob`/`JobStore` run entirely in-process, in the
foreground; `UIBackgroundModes` only declares `audio` (keeps the process alive during *live
mic recording*). A **file/link transcription job
has no such cover** — if the user backgrounds the app mid-job, the job is vulnerable to
suspension. `BGContinuedProcessingTask` is the correct fix: wrap the ASR+diarization run in a
continued-processing task, report `Progress` from the pipeline's existing stage/percentage
model (`TranscriptionJob.advance(stepIndex:stageText:progress:)` already tracks exactly this
shape), and pair it with the **Live Activity work already spec'd in `DETAIL-REDESIGN.md`**
("Recording Live Activity" — this extends that same ActivityKit lane to a **"Transcribing"
Live Activity** for file/link jobs, not just live recording).

**Sequencing note:** this depends on (comes after) the `DETAIL-REDESIGN.md` Live Activity
lane landing, since it reuses the same widget/Live-Activity extension target and ActivityKit
plumbing that lane already adds.

**User value:** a file/link transcription job (or a long meeting recording finishing its
diarization pass) survives the user switching apps or locking the phone.

**Effort:** M. **TS-applicability:** High — directly named by Fernando, and closes a real
current gap. **Deploy-target impact:** none (iOS 26+ API, already inside the iOS 27 floor).

---

## 10. MetricKit (redesigned) — metrics + logs

**What it is.** The Swift-first `MetricManager` surface: launch/hang/animation-hitch/CPU-GPU-
disk-network diagnostics, crash/hang capture, and **state reporting** — tagging metrics with
app-defined flows so a hang or hitch can be attributed to *which pipeline stage* it happened
during.

**How it applies.** TS already has a parallel, purpose-built diagnostics story
(`PipelineRecorder`/`PipelineEvent`/`InspectorStore`/`SystemLoadSampler`) for the transcription
pipeline itself — that stays as-is, it's the in-app inspector's model. MetricKit is additive:
**system-level** production diagnostics (launch time, hangs, memory pressure, crashes) Fernando
sees across real installs in the field. `MetricManager`'s state reporting is the bridge: wrap
the app's existing pipeline stages as MetricKit states so a production hang report says
"hang during diarization," not just "hang."

**User value:** indirect but real — catching regressions in a CPU/GPU/ANE-heavy on-device app
from real usage before they become support tickets.

**Effort:** S-M. **TS-applicability:** Medium (developer/quality-facing).
**Deploy-target impact:** none.

---

## 11. Location — recording-location metadata

**What it is.** Attach a coarse location (or resolved place name via `CLGeocoder`) to a
session at creation time, opt-in.

**How it applies.** `TranscriptSession` has no location field today. Add an optional
`locationName: String?` (+ optionally raw coordinates via a SwiftData Codable attribute — a
correct use of that escape hatch, unlike capability 2's structured extraction) captured once
at session-start if the user opts in (`NSLocationWhenInUseUsageDescription`, off by default —
this is exactly the kind of feature that should never be a silent default given TS's
"nothing leaves your device" privacy pitch). Fold the place name into the Spotlight index so
"the meeting at the office" becomes a semantic hook Flagship A can use, and surface a Maps
deep-link chip alongside extracted places (capability 6's ecosystem table) as the same
suggestion-chip pattern from capability 5.

**User value:** real but secondary — supports the flagships' semantic recall without being a
headline feature on its own.

**Effort:** S. **TS-applicability:** Medium. **Deploy-target impact:** none.

---

## 12. SwiftData — sectioning, Codable attributes, ResultsObserver/HistoryObserver

**What it is.** Three independent SwiftData additions.

- **`@Query(... sectionBy:)`** — native sectioned fetches, applied to the redesigned home list
  (section by day/week or `SessionKind`). **S effort, Medium applicability.**
- **Codable attributes** — the correct escape hatch *if* Location (capability 11) stores a raw
  `CLLocationCoordinate2D` rather than just a place-name string. **S effort, Low-Medium
  applicability**, dependent-only — and explicitly *not* the right tool for capability 2's
  extraction data (see that section's storage note).
- **`ResultsObserver`/`HistoryObserver`** — closes a real current gap.
  `TranscriptSpotlightIndex.reindexAll`'s own doc comment says it's "called on launch so
  external/seeded changes are covered" — a session created/edited/deleted on the *other*
  device (Mac↔iOS sync is already wired) is only reflected in this device's
  Spotlight index on next launch, not the moment sync lands. `HistoryObserver`, filtered by
  transaction author, closes that gap: reindex incrementally the moment a synced change
  arrives. This directly firms up both flagships' data freshness across devices.

**Effort:** S / S / S-M. **TS-applicability:** Medium / Low / **High** (HistoryObserver).
**Deploy-target impact:** none.

---

## 13. Liquid Glass / SwiftUI 27 — design system, adaptive layout

**What it is.** The universal Liquid Glass material, iPhone resizability, SwiftUI documents,
reorderable containers, swipe actions beyond `List`, toolbar visibility priority.

**How it applies — mostly already in flight, not a gap.** `REDESIGN.md` and
`DETAIL-REDESIGN.md` already carry an explicit cross-cutting-audit mandate against this exact
capabilities doc, and already reference `Button(role: .close)`, the bottom toolbar bar,
`safeAreaBar`, and `confirmationDialog(item:)` as adopted APIs. This roadmap's job is only to
flag what those two specs don't explicitly cover:
- **Resizable iPhone / iPad-mirrored layout.** Neither spec mentions a size-class/adaptive
  layout audit explicitly — worth an explicit pass once the redesign lands, using Xcode 27's
  resize-handle previews, given TS's floating circular controls and mini-player currently
  assume a fixed-feeling layout.
- **Reorderable containers**: Low applicability — the session list is chronological by design,
  nothing to reorder. Skip.

**Effort:** S (the one addition), already budgeted elsewhere for the rest.
**TS-applicability:** Medium (largely already covered). **Deploy-target impact:** none.

---

## 14. Visual Intelligence / Vision — honest assessment: Low/None

TS is a pure-audio transcription app with no camera/photo intake path today. Visual
Intelligence (camera-pointed-at-an-object → matching app content) and Vision's OCR/
segmentation/barcode tools have no natural surface here. The one theoretical bridge — Vision
OCR on a photo of meeting notes/a whiteboard attached to a recording — is not a planned TS
feature. **Applicability: None** for the current product shape; revisit only if a future
"attach a photo to a session" feature is scoped, and even then it would be Low/Medium.

---

## 15. StoreKit / monetization — a decision point, not a build item

**What it is.** Subscriptions, monthly-billing-for-annual, offer-code redemption, unified App
Store Connect review submissions.

**How it applies.** `PROJECT_GUIDE.md` frames TS's job as "FCT's daily transcription driver,
and a craft showcase" — there is no stated consumer monetization model today, and no StoreKit
code exists in the repo. **This is a decision to surface, not a capability to build against a
guess.** If/when scoped: `SubscriptionStoreView` + the unified review-submission workflow are
the right on-ramp.

**Effort:** N/A until scoped. **TS-applicability:** Low / decision-needed.
**Deploy-target impact:** none.

---

## 16. Background Assets — already implemented; ship-time steps only

**What it is.** Already fully built (`Documentation/BACKGROUND-ASSETS.md`): the iOS app
pre-downloads the ~1.53 GB WhisperKit model via a self-hosted ExtensionKit downloader before
first launch. Code, manifest, and foreground fallback are complete and tested; only the
App-Store-install-triggered *firing* of the pre-launch download can't be exercised on a
sideload.

**Remaining work is exactly four ship-time steps**, already documented: (1) host the manifest
at the real `BAManifestURL`, (2) verify the HuggingFace CDN redirect domains are covered by
`BADownloadDomainAllowList`, (3) sign with a real `DEVELOPMENT_TEAM` so the
`com.apple.developer.background-assets` entitlement can be re-added and provisioned, (4)
regenerate the manifest if the shipped model variant changes.

**Effort:** none (build) / S (ship-time checklist). **TS-applicability:** already High
(shipped). **Deploy-target impact:** none.

---

## Ranked build sequence

The two flagships first, then their shared substrate's direct dependents, then everything
else. Dependencies noted; independent items can run in parallel lanes.

| # | Item | Effort | Depends on | Feeds |
|---|---|---|---|---|
| 1 | **Flagship A: library-wide Spotlight RAG Q&A** | L | Named-index `CoreSpotlightSource` delegate + full-text hydration (new); `AIToolSafetyPolicy`-style vetting (new) | The app's headline Siri capability |
| 2 | **Flagship B: Foundation Models extraction layer** | L | Foundation Models (already wired) | Everything below in this table, plus Flagship A's retrieval quality |
| 3 | **EventKit — Calendar/Reminders proactive actions** | M | #2 | The "wow" that makes extraction felt |
| 4 | **Contacts — speaker mapping, auto-detect, Siri resolution** | M | #2 (auto-detect), #1 (resolver wiring); speaker-mapping alone is independent | Both flagships' name-handling quality |
| 5 | **Proactive suggestion UX (chips)** | M | #2; wires into #3/#4 | Delivery mechanism for all of Flagship B |
| 6 | **SwiftData `HistoryObserver` incremental reindex** | S-M | — (independent) | Both flagships' data freshness across synced devices |
| 7 | **Background GPU inference (`BGContinuedProcessingTask`)** | M | `DETAIL-REDESIGN.md` Live Activity lane | Reliability for long file/meeting jobs |
| 8 | App Intents expansion (`LongRunningIntent`/cancellation, `RelevantEntities`, on-screen annotation, `OwnershipProvidingEntity`) | M | — (independent) | Siri/Shortcuts polish |
| 9 | PCC escalation for long transcripts | M | Foundation Models (already wired) | Removes on-device context ceiling |
| 10 | MetricKit `MetricManager` + state reporting | S-M | — (independent) | Production quality signal |
| 11 | Location metadata + Maps chip (opt-in) | S | — (independent); Codable-attribute dependency if raw coordinates stored | Flagship A's semantic recall (place) |
| 12 | SwiftData sectioning (`@Query sectionBy`) | S | REDESIGN.md list surface | Presentation only |
| 13 | Adaptive/resizable iPhone-iPad audit | S | REDESIGN.md + DETAIL-REDESIGN.md landing first | Cross-platform polish |
| 14 | Dynamic Profiles refactor (ask/summarize/extract unification) | S | #2 shipping (needs 3rd verb to justify) | Architecture cleanliness, not user-facing |
| — | StoreKit/monetization | — | **Fernando decision** on business model | N/A until scoped |
| — | Background Assets | — | Done — ship-time checklist only | N/A |
| — | Visual Intelligence / Vision | — | None planned | N/A |

## Deploy-target decision

**Already made and already correct: iOS 27 / macOS 27 floor on both platforms**, forced by
the Core AI diarizer. No `#available`-gating-by-OS-version work is needed anywhere in this
roadmap — every capability above is unconditionally available. The only availability checks
that remain (and already exist as a pattern in `SessionIntelligence`/`AskVillainArcAssistant`)
are *runtime capability* gates: `SystemLanguageModel.default.availability` (Apple Intelligence
eligibility/enablement), Contacts/Calendar/Reminders/Location permission grants, and Neural-
Engine-class checks if `BGContinuedProcessingTask`'s compute-unit selection needs a fallback.
None of these are `#available(iOS 27, *)` checks — they're runtime state checks the app
already knows how to do gracefully.

## Top priorities

1. **Flagship A — Siri semantic Q&A** (L) — port `AskVillainArcAssistant`'s shape, point
   `SpotlightSearchTool` at TS's own **named** index via a `CoreSpotlightSource` delegate, and
   hydrate full transcript text at query time instead of the 280-char preview.
2. **Flagship B — Foundation Models extraction layer** (L) — the structured
   decisions/action-items/events/people/places substrate. Nothing in EventKit, Contacts
   auto-detection, or the proactive suggestion chips can exist without this landing first, and
   it directly strengthens Flagship A's retrieval quality.
3. **EventKit proactive actions** (M) — the single biggest "wow" beyond Q&A: a meeting
   decision becomes a real Calendar event or Reminder, draft-then-confirm, never silent.
4. **Contacts — speaker mapping + auto-detect + Siri resolution** (M) — makes "Sergio" real
   everywhere: the UI, the search, and the suggestions. The connective tissue between both
   flagships.
5. **Proactive suggestion UX** (M) — the chip surface that makes extraction *felt* rather
   than a backend capability nobody sees; needs a real taste-checklist pass given it's a
   brand-new UI pattern.
6. **`HistoryObserver` incremental reindex** (S-M) — closes the one real data-freshness gap
   (Spotlight index only refreshes on launch today for cross-device changes),
   quietly load-bearing for both flagships.

Everything else (Background GPU inference, App Intents polish, PCC escalation, MetricKit,
Location, SwiftData sectioning, the adaptive-layout audit) is real, buildable, and worth
doing, but none of it is load-bearing for "best transcription app on the iOS 27 launch" the
way the top six are. StoreKit and Visual Intelligence are correctly Low/None/decision-needed,
not gaps.
