#!/usr/bin/env bash
# Generate the Background Assets manifest for the speech models from a real on-disk copy of
# them. The manifest lists every file of every model with its EXACT byte size — Background
# Assets fails a download whose delivered size doesn't match, so the sizes must come from the
# actual files (this script), never an estimate.
#
# The output is committed at Sources/App/BackgroundAssets/speech-model-manifest.json and a copy
# is pushed to the hosted repo beside the models (see Documentation/BACKGROUND-ASSETS.md).
#
# Usage: scripts/gen-ba-manifest.sh [models-root]   (default: the app's own models root)
set -euo pipefail

REPO="fcttechnologies/fctspeech-coreml"
MODELS=(parakeet-v3 sensevoice sortformer)
DEFAULT_ROOT="$HOME/Library/Application Support/TranscriptionStudio/Models/fctspeech"
ROOT="${1:-$DEFAULT_ROOT}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/App/BackgroundAssets/speech-model-manifest.json"

for m in "${MODELS[@]}"; do
  if [[ ! -d "$ROOT/$m" ]]; then
    echo "Model dir not found: $ROOT/$m" >&2
    echo "Install the models first (run the app once, or copy them from FCTSpeech's conversion)." >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUT")"
cd "$ROOT"
{
  echo "{"
  echo "  \"repo\" : \"$REPO\","
  echo "  \"assets\" : ["
  first=1
  total=0
  for m in "${MODELS[@]}"; do
    while IFS= read -r f; do
      rel="${f#./}"
      size=$(stat -f%z "$f")
      total=$((total + size))
      if [[ $first -eq 1 ]]; then first=0; else echo ","; fi
      printf '    { "path" : "%s", "size" : %s }' "$rel" "$size"
    done < <(find "./$m" -type f ! -name '.DS_Store' | sort)
  done
  echo ""
  echo "  ]"
  echo "}"
} > "$OUT"

total=$(python3 -c "import json,sys; print(sum(a['size'] for a in json.load(open(sys.argv[1]))['assets']))" "$OUT")
echo "Wrote $OUT ($(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['assets']))" "$OUT") files, $total bytes)."
echo "Set BAMaxInstallSize in project.yml to $total if it changed."
