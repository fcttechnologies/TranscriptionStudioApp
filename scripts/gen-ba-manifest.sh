#!/usr/bin/env bash
# Generate the Background Assets manifest for the WhisperKit turbo model from a real on-disk
# copy of the model. The manifest lists every file the variant is made of with its EXACT byte
# size — Background Assets fails a download whose delivered size doesn't match, so the sizes
# must come from the actual files (this script), never an estimate.
#
# The output is committed at Sources/App/BackgroundAssets/whisperkit-model-manifest.json
# and, at ship time, a copy is hosted at the app's BAManifestURL (see Documentation/BACKGROUND-ASSETS.md).
#
# Usage: scripts/gen-ba-manifest.sh [path-to-model-variant-dir]
set -euo pipefail

REPO="argmaxinc/whisperkit-coreml"
VARIANT="openai_whisper-large-v3-v20240930_turbo"
DEFAULT_DIR="$HOME/Library/Application Support/TranscriptionStudio/Models/whisperkit/models/$REPO/$VARIANT"
MODEL_DIR="${1:-$DEFAULT_DIR}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/App/BackgroundAssets/whisperkit-model-manifest.json"

if [[ ! -d "$MODEL_DIR" ]]; then
  echo "Model dir not found: $MODEL_DIR" >&2
  echo "Download the turbo model first (run the app once, or scripts/fetch-models.sh)." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

cd "$MODEL_DIR"
{
  echo "{"
  echo "  \"repo\" : \"$REPO\","
  echo "  \"variant\" : \"$VARIANT\","
  echo "  \"assets\" : ["
  first=1
  while IFS= read -r f; do
    rel="${f#./}"
    size=$(stat -f%z "$f")
    if [[ $first -eq 1 ]]; then first=0; else echo ","; fi
    printf '    { "path" : "%s", "size" : %s }' "$rel" "$size"
  done < <(find . -type f | sort)
  echo ""
  echo "  ]"
  echo "}"
} > "$OUT"

echo "Wrote $OUT"
echo "Total size: $(find . -type f -exec stat -f%z {} \; | awk '{s+=$1} END{print s}') bytes"
