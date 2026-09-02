#!/usr/bin/env bash
# Build Transcription Studio for iOS (Release) and install it on Fernando's paired iPhone.
# Run: scripts/install-ios.sh [device-udid]
#
# The mechanism — device resolution, signing, the dSYM archive (every extension's, not the app's
# alone), the install — is FCTFoundation's; this passes Transcription Studio's facts. The shortcut
# count is the TWIN of scripts/gate.sh's iOS count, checked here against the artifact that ships to
# the phone rather than a simulator build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/../FCTFoundation/scripts/install-ios.sh" \
  --project "$ROOT/TranscriptionStudio.xcodeproj" --scheme TranscriptionStudio \
  --expect 10 "$@"
