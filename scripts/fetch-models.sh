#!/bin/bash
# Fetch the Sortformer diarizer artifacts into Application Support (the app also has a
# runtime downloader; this is the dev/CI shortcut). WhisperKit downloads its own models.
set -euo pipefail

BASE="https://huggingface.co/mlboydaisuke/Streaming-Sortformer-Diar-CoreAI/resolve/main"
DEST="$HOME/Library/Application Support/TranscriptionStudio/Models"
MODEL_DIR="$DEST/sortformer_float16.aimodel"

mkdir -p "$MODEL_DIR"

fetch() { # path, destination
  local rel="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "have    $rel"
  else
    echo "fetch   $rel"
    curl -sL --fail -o "$out" "$BASE/$rel"
  fi
}

fetch "metadata.json" "$DEST/metadata.json"
fetch "sortformer_mel_filters_128x257.f32" "$DEST/sortformer_mel_filters_128x257.f32"
fetch "sortformer_float16.aimodel/metadata.json" "$MODEL_DIR/metadata.json"
fetch "sortformer_float16.aimodel/main.hash" "$MODEL_DIR/main.hash"
fetch "sortformer_float16.aimodel/main.mlirb" "$MODEL_DIR/main.mlirb"

# Verify the big graph landed whole (a partial .aimodel poisons Core AI's spec cache).
SIZE=$(stat -f%z "$MODEL_DIR/main.mlirb")
EXPECTED=236655368
if [[ "$SIZE" -ne "$EXPECTED" ]]; then
  echo "ERROR: main.mlirb is $SIZE bytes, expected $EXPECTED — deleting partial file" >&2
  rm -f "$MODEL_DIR/main.mlirb"
  exit 1
fi

MEL_SIZE=$(stat -f%z "$DEST/sortformer_mel_filters_128x257.f32")
if [[ "$MEL_SIZE" -ne $((128 * 257 * 4)) ]]; then
  echo "ERROR: mel filterbank is $MEL_SIZE bytes, expected $((128 * 257 * 4))" >&2
  exit 1
fi

echo "OK: Sortformer artifacts complete at $DEST"
