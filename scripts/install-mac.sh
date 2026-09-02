#!/usr/bin/env bash
# Build the Transcription Studio Mac app (Release) and install it as a double-clickable app.
# Run: scripts/install-mac.sh [destDir]     (default dest: /Applications)
#
# The mechanism — the signing identity, the build, the dSYM archive, the install — is
# FCTFoundation's; this passes Transcription Studio's facts. Signing matters most here: the Mac
# slice's TCC grants (Screen Recording for meeting capture, Microphone) are keyed to the code
# identity, so the stable Apple Development cert is what keeps them across rebuilds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/../FCTFoundation/scripts/install-mac.sh" \
  --project "$ROOT/TranscriptionStudio.xcodeproj" --scheme TranscriptionStudio \
  --expect 10 "$@"
