# TranscriptionStudio — Single-View Redesign (spec)

Consolidates the three tabs (Transcribe / Record / Library) into one surface.
Reference aesthetic: a clean dark list (a "Conversations"-style feed) with floating circular
controls — adapted as ours, not a clone. Taste bar: no AI-slop, distinctive, calm.

## The one view
The sessions list is home. Everything returns to it.

## Floating controls (over the list)
- **Top-left** — Inspector (opens a **sheet**, see below)
- **Top-right** — Settings (opens a **sheet**)
- **Bottom-left** — Search (over sessions)
- **Bottom-right** — a "+" menu:
  - Upload media / video from Photos
  - Start recording
  - Insert link (**macOS only** — URL ingest is Mac-only)

Transcribe and Record are no longer tabs — they become "+" menu actions.

## Sheets & dismissal
- The **Inspector is a sheet on BOTH platforms** (not a Mac inspector column) — one consistent
  presentation. **Large detent only** (omit `.medium` — it defaults to large).
- **No "Done" toolbar buttons.** Sheets dismiss via an elegant close affordance learned from
  Apple's own apps — a **circular `xmark` button** (gray translucent circle, top corner), the
  App Store / Music pattern. This is the standard for every sheet (Inspector, Settings, the
  live-recording sheet, session detail).

## Where the work happens — the mini-player
Active audio uses an **Apple Music-style mini-player**: a floating pill/bar near the bottom that
**expands to a full sheet on tap**. No modals interrupt the list.
- **Recording** → the mini-player shows the live recording with **animated waveforms while
  talking**; tapping it brings up the full **live recording sheet**. The bottom-right **"+"
  becomes a Stop button** while recording. Stop → it becomes a session in the list.
- **Playback** (a saved session's audio) → the same mini-player shows what's playing; tap to
  expand to the session / now-playing sheet.
- **Upload / link transcription jobs** (no live audio) → a progress row in a **section above the
  list** while running; on completion it drops into the list as a session.

Reference: Apple Music's mini-player (floating bar → expandable now-playing sheet).

## Loading / preparing / download → toasts
All model load / download / prepare / progress states surface as **toasts** (a global toast host,
ported from JA's `ToastCenter`/`ToastOverlay`), not inline banners or dedicated views. This
absorbs the "toasts" half of the model-mgmt lane.

## Permissions → Settings
The mic + screen-recording permission UI (the cards formerly on the Record surface —
`ScreenRecordingCard` / `MicrophoneCard`) move into the **Settings sheet** as a Permissions
section. Record itself just prompts/links when needed.

## Carried from the in-flight iOS-UX lane (not redone)
Swipe-to-delete + per-row confirm, stale-job cleanup on delete, silent-mode playback override —
all keep working under the new shell.

## Still queued alongside (model-mgmt lane, task 27)
Downloaded-models list + sizes + delete (in Settings), background download. The toasts piece of
that lane is pulled into this redesign.

## Build order + the bar
The bar is **elegance** — a premium, refined app, not a functional prototype.
Build on a **Fable** lane (long-horizon), grounded in **VillainArc** (`~/Projects/VillainArc`)
and **Personal Context** — FCT's own polished SwiftUI apps: inherit their design language,
component craft, and motion — plus the `taste` + apple `design` skills (reference board before
building).
Sequence: after the `iosux` + `titlegen` lanes land (they touch the same nav files this rebuilds).
