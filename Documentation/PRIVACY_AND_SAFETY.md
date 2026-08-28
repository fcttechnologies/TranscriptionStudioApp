# Transcription Studio — Privacy & Safety

Transcription Studio records and transcribes conversations: the most sensitive user-generated
content an app can hold. **Transcription, diarization and synthesis are on-device.** What the app
does *store* — the recording, the transcript, and everything read off it — syncs into the user's
own FCT account, so the library follows them across their devices. That is the one place data
goes, and it is what the privacy manifest, the App Store privacy label and the permission copy
must all say.

## Data inventory

| Class | Examples | Storage | Leaves device? |
|---|---|---|---|
| Recordings | mic capture, macOS meeting capture, imported files, ingested links | `TranscriptSession.audioData` → `BlobStore`, App Group | the user's own FCT account (`SupabaseStorageTransport`) |
| Transcript | `TranscriptSession.fullText`, `StoredSegment.text` + word timings | SwiftData | the user's own FCT account, as records |
| Extracted highlights | decisions, action items, events, people, places | SwiftData | the user's own FCT account, as records |
| Speaker bindings | `SpeakerAssignment.displayName` + `CNContact.identifier` | SwiftData | the user's own FCT account, as records |
| Recording location (opt-in) | `locationName` + full-resolution `latitude`/`longitude` | SwiftData | the user's own FCT account, as record columns |
| Device presence | `MacPresence` device id / name / last-seen heartbeat, `claimedBy` | SwiftData | the user's own FCT account, as records |
| Account | email address, account id | Shared keychain (FCTAccount) | the FCT account service |
| Long-transcript generation | transcript text above the on-device context budget | — | **Apple Private Cloud Compute**, not retained (see below) |
| Voice profiles + prompt cache | reference clips, derived prompt transcripts | Application Support | never |
| Models | WhisperKit / Sortformer / LuxTTS weights | App Group + Application Support | never (downloaded, never uploaded) |
| Diagnostics | `PipelineStateReporter` stages, MetricKit payloads | local only — FCTMetrics' uploader is never started | never |

No third-party SDKs, no analytics, no ads, no tracking. The vendored engines
(WhisperKit / SpeakerKit / TTSKit / FluidAudio) run locally and open no telemetry channel.

**Nothing is derived on a server.** The FCT account holds the user's own rows and blobs under RLS;
no model runs on them, and no content is read for any purpose but handing it back to that user's
other devices.

## Private Cloud Compute

`SessionIntelligence.generate` escalates a *single* generation call to
`PrivateCloudComputeLanguageModel` when the transcript overflows the on-device context budget, and
otherwise stays on `SystemLanguageModel.default`. PCC is Apple infrastructure with no retention and
no Apple-side identity, but it is still transcript text leaving the device: the App Store privacy
label and the privacy policy have to say the app uses PCC for long-transcript summarization.

## Permissions

- **Microphone** — asked at the first record tap, never at launch.
- **System audio capture** (macOS) — asked when meeting capture starts.
- **Location** — asked only if the user turns the recording-location tag on; off by default.
- **Contacts** — read access asked only when resolving mentions. Binding a speaker to a contact
  needs no permission at all (`CNContactPickerViewController` runs out of process).
- **Calendar** — write-only scope; the app only ever adds an event the user confirmed.
- **Reminders** — full access, because Reminders has no write-only scope; the app only ever adds.
- **Face ID / Touch ID** — for the per-session privacy lock (`Documentation/PRIVACY-LOCK.md`).

**Every usage string states two facts separately: where the work happens, and where the result is
kept.** A prompt that collapses them into "nothing leaves your device" contradicts the privacy
manifest sitting beside it — a rejection, and worse, a promise to the user this app does not keep.
The recordings sync as blobs and `location_name`/`latitude`/`longitude` are columns on the
`transcript_session` wire, so no string in `project.yml`'s `info.properties` may claim otherwise.
The same rule binds the in-app copy: the Settings footer, the permissions footer and anything that
narrates the intelligence surface, which escalates to Private Cloud Compute for a long transcript.

## Logging policy (hard rules)

- **Never log transcript content, prompt bodies, speaker names or a session title.** Runtime values
  use private interpolation; stages, counts and durations are public.
- `PipelineStateReporter` carries coarse stage labels only, never text.

## Safety

- No public or shared user content, no strangers, no child-directed features. Age rating 4+.
- A session marked private is never Spotlight-indexed, never donated as a Siri entity, and never
  returned by a library query (`Documentation/PRIVACY-LOCK.md`).
- Export is user-initiated and local: `TranscriptExport` formats a session as plain text, Markdown,
  SRT, VTT or DOCX and the user hands it to a share sheet, the pasteboard or a file. The app sends
  nothing on their behalf.
- Deleting a session deletes its rows, its blob and its Spotlight entry.

## Privacy manifest

`PrivacyInfo.xcprivacy` ships in **each of the four bundles** — the app, the Share extension, the
widget extension and the Background Assets extension — because a bundle's declarations never
inherit from the app that embeds it, and a linked Swift package (FCTFoundation, the vendored
engines) ships no manifest of its own, so whichever bundle embeds its code declares for it.
`scripts/gate.sh` reads all six shipped copies (four on iOS, two on macOS) out of the built
products: a manifest authored into a directory that is not on the target's source paths appears in
no artifact and no build reports it.

No tracking and no tracking domains, in any of the four.

**Required-reason APIs.** The app declares user defaults (**CA92.1** — its own suite only: model
and voice choices, the live-caption size step, the per-install companion device id, the
first-launch bootstrap flag, FCTAccount's session preferences) and file timestamps (**C617.1** —
`LuxTtsCloningEngine` keying its prompt cache on a reference clip's modification date in
Application Support, and FCTMetrics dating the MetricKit payload it wrote into the App Group
container). The three extensions declare **none**: each links no package, and their own sources
touch no covered API — confirmed against the built binaries, which reference no
`NSUserDefaults`, `stat` family, `statfs`, `getattrlist`, `mach_absolute_time` or
`activeInputModes` symbol.

**Collected data types are the app's alone**; the extensions transmit nothing. The app declares
email address and user id (the FCT account), device id (the presence heartbeat and job claims),
audio data (the recording blob), name (speakers, people named in a transcript, an action item's
owner, a meeting's attendees), contacts (the bound `CNContact.identifier`), other user content
(titles, transcript, source URLs, extracted highlights) and precise location (the opt-in recording
tag's latitude/longitude) — every one linked to the account, none for tracking, all for App
Functionality. The App Store privacy label has to say exactly this.
