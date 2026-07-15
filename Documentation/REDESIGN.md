# TranscriptionStudio — Single-View Redesign (spec)

Consolidates the three tabs (Transcribe / Record / Library) into one surface.
Reference aesthetic: a clean dark list (a "Conversations"-style feed) with floating circular
controls — adapted as ours, not a clone. Taste bar: no AI-slop, distinctive, calm.

## The one view
The sessions list is home. Everything returns to it.

## Floating controls (over the list)
- **Top-left** — Inspector
- **Top-right** — Settings
- **Bottom-left** — Search (over sessions)
- **Bottom-right** — a "+" menu:
  - Upload media / video from Photos
  - Start recording
  - Insert link (**macOS only** — URL ingest is Mac-only)

Transcribe and Record are no longer tabs — they become "+" menu actions.

## Where the work happens
- **Record** → a focused live-recording view presented over the list.
- **Upload / link** → a job that appears **inline in the list** with live progress; tap to open
  the result. (Open question for Fernando: recording inline too, or presented — currently presented.)

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

## Build order
After the `iosux` + `titlegen` lanes land (they touch the same nav files). Then build as a
taste-driven design pass (load the `taste` + apple `design` skills; reference board first).
