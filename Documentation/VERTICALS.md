# Verticals — Market Research + Persona Map

Research pass to answer: who uses transcription/voice-note apps, how, what they need — and
what would make each of them say "damn, how does it do all that." Web-grounded (July 2026
market), mapped against TS as it is and as roadmapped (`PROJECT_GUIDE.md`, `DETAIL-REDESIGN.md`,
the iOS-27 assistant-layer plans: Siri semantic Q&A over transcripts, Foundation Models
extraction → Calendar/Reminders/Contacts, share sheet, CloudKit sync, iOS↔Mac companion).

## The competitive field (where TS sits)

- **Otter.ai** — the default for meetings/sales; cloud-only, bot-joins-your-call model. 2026's
  biggest story about it is **not** accuracy — it's the *In re Otter.AI Privacy Litigation*
  (consent to record/train), plus recurring complaints about speaker-ID drift, surprise billing,
  and support. Trust is actively eroding, which is a live opening.
- **Rev** — human-reviewed tier for when 99%+ accuracy is non-negotiable (legal, medical);
  AI tier for everything else. The category's "adult in the room" for stakes-matter audio.
- **Fireflies / Read.ai / Fellow / Zoom AI Companion / Gong / Chorus** — the sales/meeting-bot
  cluster: auto-join Zoom/Meet/Teams, CRM sync (Salesforce/HubSpot), talk-ratio and coaching
  analytics. Built for *scheduled remote calls*, not in-person or ad hoc capture.
- **Descript** — transcription-as-editing-surface for podcast/video producers (edit audio by
  editing text, Studio Sound, clips).
- **Sonix / Trint / HappyScribe / GoTranscript** — the "serious accuracy + export formats"
  tier journalists, legal, and podcasters route to when generic bots aren't trustworthy enough.
- **Apple Voice Memos / Live Captions / Notes** — the on-device baseline everyone already has:
  free, private, no accounts, but no diarization worth using, no structured extraction, no
  real "ask my transcripts" layer, and Live Captions is a separate, transcript-less mode.
- **Vertical-specific AI scribes** (AutoNotes, Supanote, TheraPro, DeepCura for clinicians;
  FieldScribe AI for inspectors/adjusters) — thin capture UI, but the *output template* is
  the whole product (SOAP notes, survey reports). This is the pattern to notice: winning a
  vertical is rarely about raw transcription quality anymore (Whisper-class ASR commoditized
  that) — it's about **what structured thing comes out the other side**, in whose format.
- **The one gap nobody in the field owns**: a single **on-device, offline, universal** app
  that's *actually* premium (not a hobbyist Whisper wrapper) and serves every vertical through
  one elegant surface instead of forcing a different bot per job. TS's on-device pipeline +
  CloudKit-native sync + iOS-27 assistant layer is built to be exactly that.

---

## Verticals

Each: who · workflow · needs · pain points with the field · the "damn" moment.

### 1. Business meetings (internal + cross-team)
- **Who:** anyone in a recurring standup, all-hands, or planning meeting.
- **Workflow:** record or bot-join a call → get a transcript + summary → skim for what applies
  to them → action items land somewhere (Slack, email, a task app).
- **Needs:** fast, accurate multi-speaker transcript; a summary that's actually skimmable;
  action items extracted with owners; searchable across past meetings.
- **Pain:** bot-join friction and "another app watching my calendar"; summaries that hallucinate
  or flatten nuance; action items that don't land anywhere real, so they get re-typed by hand.
- **Damn moment:** speak "remind me to send Sarah the deck Friday" mid-meeting, and by the time
  the meeting ends there's already a Reminder sitting there, correctly dated, no re-typing.

### 2. Sales (calls, CRM notes, deal tracking)
- **Who:** SaaS AEs, real-estate agents, insurance/financial advisors — anyone whose calls are
  the product.
- **Workflow:** call → transcript → manually or semi-automatically log to CRM (Salesforce/HubSpot)
  → pull talk-ratio/sentiment for coaching → next-step follow-up.
- **Needs:** CRM-shaped output (not prose — fields: objection, next step, budget, timeline),
  speaker-attributed quotes for exact language capture, searchable history "what did I promise
  Client X last quarter."
- **Pain:** Gong/Chorus/Otter are subscription-heavy ($1200+/user/yr enterprise tier), require a
  bot in every call (fails for in-person/trade-show pitches), and the CRM sync is often brittle.
- **Damn moment:** ask "what did the Henderson account say about pricing across all our calls
  this year" and get a grounded, sourced answer — Siri-over-Spotlight RAG doing what today
  needs a $1200/seat platform.

### 3. Journalists & media
- **Who:** reporters, podcasters-as-interviewers, documentary/radio producers.
- **Workflow:** record interview (in-person or phone) → transcript → quote-mine for the piece →
  keep the raw record for fact-checking/legal cover.
- **Needs:** high accuracy on adversarial audio (crosstalk, phone quality, accents), fast
  turnaround (minutes not hours), exact quote-with-timestamp lookup, export that a legal/editor
  workflow can use (DOCX + TXT), rock-solid retention (never lose the source).
- **Pain:** Otter's consent/training controversy is a *direct* liability for journalists recording
  sources under confidentiality expectations; cloud tools mean the source's words sit on a
  vendor's server indefinitely.
- **Damn moment:** on-device means the interview never left the phone — the actual selling point
  to a source worried about a leak, and to an editor worried about liability. Tap any sentence
  in the transcript to jump straight to that instant of audio for quote verification.

### 4. Legal (depositions, client interviews, case prep)
- **Who:** lawyers, paralegals, court reporters (as a supplement, not replacement).
- **Workflow:** record client intake or witness interview → verbatim transcript (not "clean")
  → timestamped, speaker-ID'd, exportable as a document with line numbers for citation.
- **Needs:** **strict verbatim** (every "um," false start, self-correction — legally significant),
  reliable speaker ID for multi-party record, timestamps, and — this is the hard requirement —
  auditability: nothing summarized away, nothing "cleaned up" without an explicit toggle.
- **Pain:** the field's own guidance says AI-only transcripts have "a dangerous accuracy gap" for
  litigation use; verbatim vs. clean-verbatim confusion is the #1 quality complaint.
- **Damn moment:** a verbatim-mode toggle that's honest about it — no silent "cleaning" of
  disfluencies — with per-word confidence visibly flagged, so a paralegal knows exactly which
  five words to double-check against the audio instead of proofreading the whole thing.
- **Flag:** genuinely privacy/liability-sensitive — CloudKit sync of privileged client material
  needs an explicit "keep this session device-only, never sync" per-session control.

### 5. Medical / clinical (dictation, patient notes)
- **Who:** physicians, nurses, clinical documentation staff.
- **Workflow:** dictate during or right after a patient encounter → structured note (SOAP-style)
  → into the EHR.
- **Needs:** speed (dictation faster than typing mid-encounter), medical-terminology accuracy,
  a structured note template (not raw transcript), and — non-negotiable — **HIPAA**: BAA
  availability, no PHI leaving a compliant boundary.
- **Pain:** the vendor landscape (DeepCura, AutoNotes, Supanote) is 100% cloud/subscription
  scribe tools that are HIPAA-compliant *by BAA*, not by architecture. Nobody's really selling
  "the data never left the device" as the compliance story.
- **Damn moment / the honest flag:** on-device transcription is *structurally* the strongest
  HIPAA story in the category (PHI never transits a server) — but TS is not a clinical-note
  generator (no SOAP templates, no EHR integration) and shouldn't chase that without dedicated
  investment. **This is a real opportunity, not a checkbox**: even without EHR integration, "your
  patient's words never leave this phone" is a message this vertical is starving for. Treat as
  a longer-horizon vertical (needs a note-template layer), not a quick win.

### 6. Academic (students, lecturers, researchers)
- **Who:** students recording lectures, professors recording their own lectures, researchers
  recording interviews for qualitative work.
- **Workflow:** record lecture/interview → transcript → study notes / quiz material (students)
  or coded analysis (researchers).
- **Needs:** long-session stability (90+ min lectures), speaker separation for panel/seminar
  recordings, searchability across a semester's worth of sessions, cheap/free (students are
  price-sensitive).
- **Pain:** the field has splintered into "capture" tools (Otter, Notta) and "study workflow"
  tools (NoteHive, CuFlow) that paste transcripts into Notion by hand — nobody owns end to end.
- **Damn moment:** ask "what did the professor say would be on the exam" across a whole
  semester's lecture library and get the answer with the exact lecture + timestamp cited.

### 7. Podcasters & content creators
- **Who:** solo and co-hosted podcasters, YouTubers, video essayists.
- **Workflow:** record → transcript → show notes / SEO description / social clips / captions —
  the transcript is raw material for five other deliverables, not the end product.
- **Needs:** speaker labels matching real names, SRT/VTT export for captions, clean paragraph
  export for show notes, quote-pull for social, ideally auto-generated highlights/clips.
- **Pain:** Descript/Sonix/Castmagic own this well already — a crowded, mature niche. TS's edge
  here is narrower: on-device privacy for pre-release interviews (nothing leaked before
  publish) and the Mac↔iOS companion for record-on-phone-edit-on-Mac.
- **Damn moment:** record a guest interview on the phone in a hotel room, and by the time you're
  back at the Mac the diarized transcript, chaptered by topic, is already there waiting.

### 8. Therapists & counselors
- **Who:** licensed therapists, social workers, psychologists (private practice + group).
- **Workflow:** session (in-person or telehealth) → progress note (SOAP/DAP/BIRP format,
  payer-specific) → filed to EHR, with PII scrubbed from any working copy.
- **Needs:** the note-*format* is the product (per the field: AutoNotes/Supanote/TheraPro all
  compete on template quality, not transcription); automatic PII scrubbing; strict
  confidentiality (session content is maximally sensitive — more so than most legal/medical).
- **Pain:** every competitor is cloud-based "trust our BAA" — none offers "this never left the
  room" as an architectural guarantee, which is exactly what a therapist's ethical obligation
  (and client's trust) is asking for.
- **Damn moment:** same as medical — on-device is the honest, structural answer to "is this
  private," in a field where every competitor can only offer a policy promise. Needs a
  note-template layer to fully win the vertical; without it, this is "great capture, no product."

### 9. Accessibility — Deaf / hard-of-hearing
- **Who:** Deaf/HoH individuals needing real-time conversation access; not a niche — an
  underserved, high-loyalty audience (Apple's own Live Captions + third-party Ava exist because
  demand is real and durable).
- **Workflow:** **live**, in-the-moment captioning of a conversation happening right now — this
  is categorically different from every other vertical (post-hoc transcript), it's real-time
  communication access.
- **Needs:** low-latency live captions (not "record then review"), large/readable on-screen text,
  reliable in noisy/multi-speaker settings (restaurants, doctor's offices), ideally works without
  a data connection (TS's on-device edge fits perfectly).
- **Pain:** Apple's own Live Captions is solid but transcript-less (nothing saved to revisit) and
  English-only-ish; Ava is good but subscription-gated for its high-accuracy tier.
- **Damn moment:** a live-caption mode that's actually just TS's existing real-time ASR pointed
  at the front mic with a big-text display — and unlike Apple's own feature, it's *saved* as a
  real session afterward (a Deaf user can revisit "what did the doctor actually say").
- **This is a genuine gap and a values-aligned one**: TS already has the on-device streaming ASR
  the feature needs; the delta is a UI mode, not new ML. High goodwill, real differentiation,
  low relative build cost.

### 10. UX research & hiring interviews
- **Who:** UX researchers running user interviews, hiring managers doing structured interviews.
- **Workflow:** interview → transcript → tag/code by theme → synthesize across many interviews
  (affinity mapping) → a findings deck or hiring decision.
- **Needs:** consistent speaker labels across a whole *study* (not just one file), the ability to
  tag/highlight passages and pull them out cross-session, export that plays with Notably/Condens-
  style tools, timestamps for going back to source.
- **Pain:** the category (Notably, Condens, Looppanel, Maze) is built as a *team research
  platform*, expensive and heavyweight for a single researcher or a hiring manager doing five
  interviews a quarter.
- **Damn moment:** ask across every candidate interview this month "who mentioned wanting to
  work with a small team" and get names + quotes + timestamps, no manual tagging ever done.

### 11. Executives, consultants, and knowledge workers
- **Who:** consultants running client workshops, execs in back-to-back 1:1s, freelancers
  billing by the conversation.
- **Workflow:** call/meeting → need the takeaway fast, rarely need the full transcript again →
  delegate follow-through (send a recap email, log an action item, update a contact record).
- **Needs:** summary quality over raw transcript fidelity, extraction into existing tools
  (Calendar/Reminders/Contacts/Mail) rather than a new silo, minimal friction (no bot-join
  ceremony for an in-person client meeting).
- **Pain:** every "AI meeting assistant" assumes a scheduled video call with a bot invited —
  none of them handle "grabbed 20 min with a client at their office."
- **Damn moment:** the Foundation Models extraction → Calendar/Reminders/Contacts suggestion
  flow, done *silently* during any recording regardless of whether it was a Zoom call or a
  hallway conversation — draft suggestions the person just taps to accept.

### 12. Personal — voice memos & journaling
- **Who:** everyone, and specifically Fernando's own daily-driver use case (FCT transcription
  workhorse first, showcase second).
- **Workflow:** quick voice note to self, a walk-and-think ramble, an idea capture, a personal
  journal entry — low structure, high frequency, deeply private.
- **Needs:** zero-friction capture (record now, think later), searchability months later
  ("what was that idea I had in the car"), complete privacy (this is the most sensitive
  content category of all — nobody else should ever see it, ever, by design not policy).
- **Pain:** Apple Voice Memos has zero transcription intelligence; journaling apps (AudioDiary,
  Speakwise, Entries) are Whisper-wrapper products without real diarization or a Mac companion.
- **Damn moment:** "what did I say about the Erick project three weeks ago" answered instantly,
  correctly, from a rambling voice memo recorded in the car — and the answer never touched a
  server. This is the vertical the whole app is secretly built around; win it and most others
  fall out for free.

### High-value niche: field service / inspection / insurance adjusting
- **Who:** insurance adjusters, home/building inspectors, property managers, contractors doing
  site walks.
- **Workflow:** walk a site narrating observations aloud (hands full, can't type) → the audio
  becomes a structured report (damage description, room-by-room, repair recommendation).
- **Needs:** works offline in basements/rural sites with no signal (a genuine TS structural
  advantage — everyone else here, FieldScribe AI included, still needs a network round-trip for
  the AI structuring step even if capture is local), photo attachment alongside the narration,
  a report template output.
- **Damn moment:** narrate a walkthrough hands-free with zero connectivity, and get a
  room-by-room structured report on the drive back — this niche is small in headcount but each
  user has real willingness to pay (it's replacing billable inspection hours).

---

## Mapping to TS: what serves what, and the gaps

| Vertical | Served today | Roadmapped (iOS-27 layer) | Gap |
|---|---|---|---|
| Business meetings | Diarization, transcript, room/meeting recording | Siri Q&A, Calendar/Reminders extraction | Meeting-bot parity (no Zoom/Teams auto-join — likely fine to never chase) |
| Sales/CRM | Transcript, speaker-ID | Siri Q&A over history | CRM export shape (structured fields, not prose); CRM integration is a real gap |
| Journalists | On-device privacy, diarization, playhead-to-quote | — | Fast DOCX/TXT export with timestamps; batch/long-file stability |
| Legal | On-device privacy, speaker-ID, timestamps | — | **Verbatim-mode toggle** (no auto-cleanup); per-word confidence surfaced; per-session "never sync" lock |
| Medical | On-device privacy (structural HIPAA story) | — | No clinical note templates, no EHR path — long-horizon, not quick |
| Academic | File/URL transcription, diarization | Siri Q&A across sessions | Long-session (90+ min) stability confidence; cheap/free tier for students |
| Podcasters | Diarization, Mac↔iOS companion | — | SRT/VTT export, chaptering/topic-segmentation, named-speaker persistence |
| Therapists | On-device privacy | — | Note templates (SOAP/DAP), PII scrubbing — long-horizon |
| Accessibility (Deaf/HoH) | Real-time streaming ASR already exists | — | **A live-caption UI mode** — smallest-build/highest-goodwill gap on this list |
| UX research/hiring | Diarization, transcript | Siri Q&A, tagging via search | Cross-session tag/highlight and theme search across a "study" (multiple sessions) |
| Executives/consultants | Room recording, transcript | **Foundation Models extraction → Calendar/Reminders/Contacts** (the single best-fit roadmap item) | None major — this vertical is the roadmap's direct target |
| Personal/journaling | File/room recording, on-device privacy | Siri semantic Q&A ("what did I say about X") | This *is* the flagship use case — polish here compounds everywhere |
| Field/inspection | On-device, offline-capable | — | Photo+narration combined capture; structured report template |

---

## Cross-cutting features — the highest-leverage build list

These serve the most verticals at once and are what make the *whole app* feel seamless rather
than a pile of per-vertical settings. Ranked by how many verticals each one moves.

1. **Siri semantic Q&A over transcript history** (already roadmapped). Nearly every vertical's
   "damn" moment above is a variant of "ask a question, get a grounded, sourced answer from past
   recordings." This single feature is the biggest lever on the list — it's the difference
   between "a transcription app" and "an app that knows what was said." Build it once, generally
   (not per-vertical query templates), and every vertical inherits it.
2. **Foundation Models extraction → Calendar/Reminders/Contacts/Mail** (already roadmapped).
   Second-biggest lever: turns passive transcript into acted-upon follow-through, the exact thing
   meetings/sales/execs/consultants are all missing from their current tools. The draft-then-
   confirm pattern (never auto-commit) keeps it trustworthy across every sensitive vertical too.
3. **A visible, honest confidence/verbatim layer.** Surfacing per-word/per-segment confidence and
   offering a true verbatim mode (no silent disfluency cleanup) serves legal directly, but also
   journalists (quote verification), academic/research (accurate coding), and builds trust
   everywhere — "the app tells you what it's not sure about" is a premium-feeling honesty move
   competitors don't make (most silently "clean" everything).
4. **Per-session privacy control (device-only / never sync).** One toggle, huge leverage: legal,
   medical, therapy, personal journaling, and journalists' source protection all need "this one
   never leaves the device or the family's CloudKit" as an explicit, visible guarantee — not an
   implicit default nobody can verify. This is also the single sharpest differentiator against
   the *entire* cloud-based field (the Otter litigation is the market handing TS this argument).
5. **Flexible structured export (beyond plain text).** DOCX/TXT/SRT/VTT/PDF cover journalists,
   podcasters, legal, academic, and UX research in one export subsystem — the field's own
   guidance ("DOCX for humans, TXT for search, SRT/VTT for captions") maps directly onto a
   small, finite set of formats worth building once.
6. **Cross-session search/theme/tag layer.** UX research, academic, sales, and personal
   journaling all independently need "find everything related to X across many past sessions" —
   the Spotlight/IndexedEntity roadmap already builds the substrate; the leverage is exposing it
   as first-class UI (not just a Siri answer) so it's browsable, not only askable.
7. **A live-caption mode off the existing streaming ASR.** Smallest lift on this list (no new ML,
   a UI mode) for the single most underserved, highest-goodwill vertical (Deaf/HoH) — and it's a
   natural side door into "this app is also genuinely for accessibility," which is a good story
   for App Store visibility/press, not just a nice-to-have.
8. **Named, persistent speakers across sessions.** Today's diarization is presumably per-session
   ("Speaker 1/2"); letting a user *name* a speaker once and have TS recognize them across future
   recordings (a returning client, a co-host, a professor) is what makes multi-session Q&A,
   sales CRM notes, and podcaster show notes all *actually* usable instead of technically correct.
   High leverage, and it's the kind of detail that produces the target "damn, how does it do
   that" reaction on its own.

## Vertical ranking — opportunity (market size × current fit × differentiation)

1. **Personal / journaling** — largest addressable market (everyone), best current fit (this is
   already the app's daily-driver use case), and the differentiator (on-device + semantic recall)
   is unmatched by any journaling competitor. Highest priority: it's also the proving ground for
   cross-cutting feature #1 and #6.
2. **Executives / consultants / knowledge workers** — huge market, and the *roadmap already
   targets it directly* (Foundation Models → Calendar/Reminders). Differentiation is strong
   (no competitor handles ad hoc in-person capture, only scheduled bot-joined calls).
3. **Sales / CRM notes** — large, well-funded market (Gong/Chorus prove people pay a lot), but
   fit requires real work (CRM export shape, ideally a HubSpot/Salesforce integration later) —
   worth it, not a quick win.
4. **Journalists / media** — smaller market, but differentiation is *maximal* right now — the
   Otter privacy litigation is a live, news-cycle-relevant argument for "your source's words never
   leave your phone." High goodwill, credible press angle, modest build (export polish, quote
   navigation already close to done).
5. **Accessibility (Deaf/HoH)** — smaller direct market, but exceptional fit (near-zero new build
   — a UI mode on existing ASR) and high differentiation/goodwill. Best "leverage per line of
   code" item on the whole list.
6. **UX research / hiring interviews** — medium market, decent fit once cross-session tagging
   exists, meaningful differentiation against expensive team-research platforms for solo/small
   use.
7. **Academic (students/researchers)** — large market but price-sensitive and crowded with
   free/cheap "study workflow" tools; fit is good, differentiation is moderate (semantic Q&A over
   a semester is a real edge, but "another lecture app" is a hard sell without marketing).
8. **Podcasters/creators** — large but mature, well-served market (Descript owns editing,
   Sonix owns export); TS's edge (on-device pre-release privacy, Mac↔iOS companion) is real but
   narrower — good secondary market, not a primary bet.
9. **Legal** — high willingness-to-pay per user but a narrow, demanding market that needs the
   verbatim/confidence feature built *right* before it's crediblely usable; worth building the
   cross-cutting feature (#3) for its broader benefit, but don't chase this vertical specifically
   without dedicated legal-workflow investment.
10. **Field service / inspection** — small niche, real differentiation (offline capability is
    genuinely rare in this category), decent willingness to pay; a good "prove the platform"
    niche but low volume.
11. **Medical / clinical** and **12. Therapists/counselors** — both have the strongest structural
    privacy story in the entire market (on-device beats every cloud competitor's BAA-based
    promise) but require dedicated note-template/EHR investment TS doesn't have today. Long-
    horizon opportunities, not near-term ones — flagging honestly rather than overselling: don't
    build toward these without committing to the template layer that actually makes the vertical
    usable, or the on-device advantage is wasted on an incomplete product.

## Biggest gaps to close for broad appeal

- **No verbatim/confidence-surfaced mode.** Every stakes-matters vertical (legal, journalism,
  academic research) needs to trust the transcript is either exactly what was said or clearly
  flagged where it isn't. This is the single gap blocking the most verticals at once.
- **No per-session privacy/sync control.** The on-device architecture is TS's whole edge, but
  without a visible, per-session "never sync this" guarantee, it's an *implicit* advantage users
  have to take on faith rather than an explicit, marketable one.
- **No cross-session tag/theme layer surfaced in UI** (vs. buried in a Siri-only answer) —
  research/sales/journaling all want to browse "everything about X," not just ask once.
- **No named-speaker persistence across sessions** — every returning-person vertical (clients,
  co-hosts, professors, patients) currently starts from zero each time.
- **No flexible export beyond whatever exists today** — DOCX/SRT/VTT are cheap to add and unlock
  four verticals' downstream workflows in one pass.
- **Live-caption mode is unbuilt** despite the underlying tech existing — the highest
  ROI-per-effort item on this entire document.
