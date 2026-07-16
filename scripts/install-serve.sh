#!/usr/bin/env bash
# Build transcribe-cli and install it to a STABLE, app-owned path — NOT .build/, which is a
# build-output dir that gets swept by build churn (worktrees, cleans, coverage runs). The 24/7
# serve LaunchAgent runs from this stable copy, so a restart/reboot can never find a missing
# binary. Re-run this after any change to the CLI to refresh the installed binary.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DEST_DIR="$HOME/Library/Application Support/TranscriptionStudio/bin"
mkdir -p "$DEST_DIR"

echo "› Building transcribe-cli (release)…"
swift build -c release --product transcribe-cli
cp .build/release/transcribe-cli "$DEST_DIR/transcribe-cli"
echo "› Installed $DEST_DIR/transcribe-cli"

# (Re)load the serve LaunchAgent onto the fresh binary.
launchctl kickstart -k "gui/$(id -u)/com.fcttechnologies.transcriptionstudio" 2>/dev/null \
  || echo "  (LaunchAgent not loaded yet — load setup/launch-agents/com.fcttechnologies.transcriptionstudio.plist)"
echo "› Serve reloaded."
