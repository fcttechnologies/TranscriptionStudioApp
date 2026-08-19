# Ship Plan — TranscriptionStudio → iOS 27 launch

Fuses `IOS27-CAPABILITIES-ROADMAP.md` + `VERTICALS.md` into one execution sequence.
**Thesis (both docs converge):** TS wins on **on-device privacy** + the **assistant layer**
(ask Siri about your conversations; conversations become actions) — not raw transcription, which
is commoditized.

## Governing principle: reusable → FCTFoundation, not app copies
Anything generalizable across FCT apps is built into the right **FCTFoundation** module and
consumed by TS — never copied per-app. VillainArc is the *reference*; FCTFoundation is the *home*.
- FM / AI / RAG / extraction machinery → **FCTIntelligence** (generalize VA's `AskAssistant` +
  the `@Generable` extraction pipeline; the app supplies its own index + schema).
- Cross-device sync → **FCTServerSync** + **FCTBlobSync** + **FCTAccount** over **FCTSync**'s
  change feed (adopted; see `TranscriptionSync`).
- Shared UI (suggestion chips, media/now-playing controls) → **FCTComponentsUI**.
- Core primitives → **FCTCore**.
- A new module only when nothing fits.
When a lane builds something VA-derived or cross-app-useful, it lands it in FCTFoundation with a
clean, app-parameterized API — not inside TranscriptionStudioApp.

## Phases (sequenced · deploy target is already iOS 27 → NO version gating anywhere)

### Phase 1 — the surface  ← STARTING
Detail-view redesign (karaoke playhead, **conditional** speaker grouping [single = flat],
elegant playback, tap-to-seek) + **Live Activities** (playback now-playing media player via
ActivityKit + `MPNowPlayingInfoCenter`; recording Live Activity) via a new widget extension.
Built **with the assistant layer in mind** — the detail view is where suggestion chips + the
Siri-Q&A entry will live, so design the room for them now. Spec: `DETAIL-REDESIGN.md`.

### Phase 2 — the brain
The FM **extraction substrate** (`@Generable` decisions / action-items / events / people / places
→ real SwiftData models) built into **FCTIntelligence** (generalized), + **Flagship A: Siri
semantic Q&A** (`SpotlightSearchTool` + FM RAG over TS's named Spotlight index) — the assistant
machinery generalized into FCTFoundation, app-parameterized.

### Phase 3 — the actions
**Flagship B** ecosystem surfaces: **EventKit** (draft-then-confirm Calendar/Reminders + an App
Intent), **Contacts** (speaker→person + auto-detected mentions + Siri name resolution), the
**proactive suggestion-chip UX** in the detail view (real taste pass — new pattern, slop risk).

### Phase 4 — the moats
The verticals gaps: **verbatim/confidence mode** (legal/medical) + a per-session **"never sync /
private" lock** (the privacy differentiation), + **live-caption mode** (near-zero cost off the
existing streaming ASR — the best ROI-per-line + highest accessibility goodwill).

### Phase 5 — supporting
Background GPU inference (`BGContinuedProcessingTask`, after Phase 1's Live Activity), **MetricKit**
(metrics + logs), flexible **export** (DOCX/SRT/VTT), cross-session tag/theme search, SwiftData
`HistoryObserver` incremental reindex (cross-device freshness).

## Ship-time checklist (deferred, not build items)
Background Assets entitlement re-add + capability enable · StoreKit/monetization decision ·
App Store assets/screenshots/review.
