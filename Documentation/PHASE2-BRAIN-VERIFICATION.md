# Phase 2 — "the brain": device-verification & API grounding

Phase 2 ships two capabilities on one substrate:

- **The FM extraction substrate** — a Foundation Models guided-generation pass over every completed
  transcript, extracting decisions / action items / events / people / places into **real, queryable
  SwiftData `@Model` types** (not Codable blobs).
- **Flagship A — Siri semantic Q&A** — a `SpotlightSearchTool`-backed on-device assistant that
  answers "what did Sergio and I decide at the last meeting?" from the whole transcript library.

Both are built on the **generalized** FCTIntelligence spine, not app-copied VA code (see
"What generalized vs stayed app-specific" below).

## What CAN'T be verified in a build lane (and must be checked on device)

The actual **Foundation Models / Siri runtime behavior** runs only on an Apple-Intelligence-eligible
device with Apple Intelligence enabled. The lane verifies the *code path* (correct documented API
usage, deterministic logic unit-tested, clean iOS-sim + macOS builds). The following are **on-device
manual checks Fernando runs** — none is claimed runtime-verified.

### Extraction substrate
1. Record or import a short meeting with a clear decision + a dated action item (e.g. "let's ship
   Friday; Sergio, send the deck by next Tuesday"). Let it finish transcribing.
2. Extraction runs **off the critical path** — the transcript appears immediately; highlights fill in
   a moment later (`session.highlightsStatus` → `.ready`).
3. Confirm the extracted models persist and are queryable: the session's `decisions`, `actionItems`
   (with `owner` + resolved `dueDate`), `events`, `people`, `places` relationships are populated.
4. Turn Apple Intelligence **off** and record again → status degrades to `.unavailable` silently (no
   highlights, **no error surface**).

### Flagship A — Siri semantic Q&A
5. With several transcripts saved, tap **"Ask your library"** (the `sparkles.magnifyingglass` toolbar
   button) and ask a cross-session question — confirm it retrieves from the *right* session(s) and
   answers from their content.
6. Via Siri/Shortcuts: run **"Ask a Transcript"** with **no** transcript chosen → it should search the
   **whole library** (Flagship A). Choose a specific transcript → it answers grounded in that one only
   (the prior single-session behavior, unchanged).
7. **Named-index scoping (the one real runtime unknown — verify explicitly).** TS donates into a
   **named** Core Spotlight index (`"TranscriptionStudioSessions"`), never the system default (only a
   named index carries a data-protection class). The `SpotlightSearchTool` beta API exposes **no
   direct index-name parameter** on `CoreSpotlightSource` — it searches "the app's Spotlight index,"
   and the `searchableIndexDelegate` we provide **hydrates full transcript text** for matched ids (the
   persisted index keeps only a 280-char preview). Confirm on device that library Q&A actually
   retrieves from the named-index content. If it does **not** reach the named index, the fallback is
   to additionally donate a lightweight copy into the default index (metadata only), keeping the
   full-text hydration delegate as-is — do **not** inflate the persisted named index.
8. **Safety boundary** — the assistant is read-only by construction (`SpotlightSearchTool` vetted
   `.readOnly` through `AIToolSafety.vettedReadOnly`); it must never create/edit/delete. Ask it to
   "delete my last transcript" → it should explain it can only answer questions.

## Apple APIs grounded live via sosumi (not training memory)

Every Apple API below was confirmed against the live iOS/macOS 27 beta docs through `sosumi` while
building this lane (training memory is stale and was not trusted):

| API | What was confirmed | Source |
|---|---|---|
| `SpotlightSearchTool` / `.Configuration(sources:…)` | `Configuration(sources: [SearchSource])`; init `SpotlightSearchTool(configuration:)`; session `LanguageModelSession(tools:)` | corespotlight/spotlightsearchtool · …/configuration-swift.struct |
| `SearchSource` | `.coreSpotlight` (default) and `.coreSpotlight(_:)` (custom `CoreSpotlightSource`) | corespotlight/searchsource |
| `CoreSpotlightSource` | `init(searchableIndexDelegate:fetchAttributes:)`; delegate **recreates non-recoverable attributes** (full-text hydration), does **not** scope the index by name | corespotlight/corespotlightsource · …/searchableindexdelegate |
| `SearchableItemAttribute` | `.title`, `.contentDescription`, `.keywords` are valid fetch attributes | corespotlight/searchableitemattribute |
| `CSSearchableIndexDelegate` | `searchableItems(forIdentifiers:searchableItemsHandler:)` (optional, hydration); the two `reindex…` methods (required, acked) | corespotlight/cssearchableindexdelegate/* |
| `Tool` (FoundationModels) | `Tool<Arguments, Output>: Sendable`; `@Generable` Arguments + `call(arguments:)` | foundationmodels/tool |
| `@Generable` / `@Guide` guided generation | `session.respond(generating:options:)`, greedy `GenerationOptions`, `contextSizeExceeded` overflow | (used in FCTIntelligence `StructuredGenerator`, confirmed) |

**Deploy floor is iOS/macOS 27 on both platforms**, so there is **no `#available` OS-version gating**
anywhere — the only gates are *runtime capability* checks (`SystemLanguageModel.default.availability`).

## What generalized into FCTIntelligence vs stayed app-specific in TS

**Generalized (FCTFoundation `main`, `Sources/FCTIntelligence/`)** — app-parameterized, reusable:
- `AIToolSafety` — `SafeTool`/`AIToolCapability(.readOnly)`, `vetted(_:allowlist:)` /
  `vettedReadOnly(_:)`, the latest-prompt history transform. VA's `AIToolSafety` generalized.
- `SemanticAssistant` — the on-device read-only "ask my own data" assistant (app supplies
  instructions + vetted read-only tools). VA's `AskVillainArcAssistant` generalized, no OS gating.
- `GuidedExtractor` — the safe front-door for guided generation over untrusted free text
  (sanitize+fence via `PromptSafety` → tier-resolve via `AIModelProfile` → generate via
  `StructuredGenerating`). Closes the gap `StructuredGenerator` leaves (it does not re-sanitize).
- `SpotlightSearchTool: SafeTool` (`.readOnly`) conformance, scoped off watchOS.

**App-specific (TranscriptionStudio, this branch)**:
- `TranscriptHighlights` — the transcript-domain `@Generable` schema (`SessionHighlights` etc.).
- `HighlightModels` + `TranscriptSession` relationships — the real `@Model` extraction types.
- `HighlightsExtractor` — TS instructions + reference-date preamble, `SessionHighlights` → `@Model`
  mapping, off-critical-path scheduling (wired into both completion hooks).
- `RelativeDateResolver` — deterministic `NSDataDetector` date-phrase → `Date`.
- `TranscriptLibraryAssistant` + `TranscriptHydrationDelegate` — TS instructions, the Spotlight RAG
  tool over the named index, full-text hydration.
- `AskTranscriptIntent` upgrade (no session → library RAG) + `AskLibraryView` (in-app Q&A surface).
