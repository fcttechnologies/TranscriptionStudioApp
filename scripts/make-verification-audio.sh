#!/bin/bash
# Build known-ground-truth multi-speaker audio for diarizer verification: distinct `say`
# voices alternating at boundaries we control, so speaker-attribution accuracy is
# computable in an automated test. Emits WAV (16k mono f32) + a JSON ground-truth file.
#
# Usage: scripts/make-verification-audio.sh [output-dir]   (default: TestResources/)
set -euo pipefail

OUT_DIR="${1:-$(dirname "$0")/../TestResources}"
mkdir -p "$OUT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Two acoustically distinct voices (diarization keys on voice distinctness; a male+female
# pair splits cleanly — the model card's own guidance).
VOICE_A="Daniel"     # UK male
VOICE_B="Samantha"   # US female
GAP_SECONDS=0.6

# Alternating utterances, long enough that turns span multiple 80ms frames.
UTTERANCES=(
  "A|Good morning everyone, thanks for joining the call today."
  "B|Happy to be here. I reviewed the proposal last night and had a few thoughts."
  "A|Great, let's start with the timeline. We are planning to ship the first milestone in March."
  "B|March feels tight given the integration work. I would suggest we add two weeks of buffer."
  "A|That's fair. Let's lock April fifteenth as the revised target and communicate it this week."
  "B|Agreed. I will draft the update and send it to the team for review tomorrow morning."
  "A|Perfect. Next topic: the budget. We are currently about ten percent under plan."
  "B|That gives us room for the extra contractor we discussed. I say we bring them on."
)

# Longer variant (>60s total) is built by repeating the dialogue 3x — long enough that
# the Sortformer speaker-cache compression actually fires (a short clip never exercises
# it; the zoo's own long-clip gate exists for exactly this reason).
build_clip() { # name, repeat_count
  local name="$1" repeats="$2"
  local concat_list="$WORK/${name}_list.txt"; : > "$concat_list"
  local json="$OUT_DIR/${name}.json"
  local cursor=0
  local index=0
  echo '{"frameDuration": 0.08, "turns": [' > "$json"
  local first=1

  for ((r=0; r<repeats; r++)); do
    for entry in "${UTTERANCES[@]}"; do
      local speaker="${entry%%|*}" text="${entry#*|}"
      local voice; [[ "$speaker" == "A" ]] && voice="$VOICE_A" || voice="$VOICE_B"
      local aiff="$WORK/utt_${name}_${index}.aiff" wav="$WORK/utt_${name}_${index}.wav"
      say -v "$voice" -o "$aiff" "$text"
      afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
      local dur
      dur=$(afinfo "$wav" | awk '/estimated duration/ {print $3}')
      [[ $first == 1 ]] || echo ',' >> "$json"
      first=0
      printf '  {"speaker": "%s", "start": %.3f, "end": %.3f}' \
        "$speaker" "$cursor" "$(echo "$cursor + $dur" | bc)" >> "$json"
      echo "file '$wav'" >> "$concat_list"
      cursor=$(echo "$cursor + $dur + $GAP_SECONDS" | bc)
      # Silence spacer between turns.
      local gap="$WORK/gap_${name}_${index}.wav"
      ffmpeg -y -loglevel error -f lavfi -i "anullsrc=r=16000:cl=mono" -t "$GAP_SECONDS" \
        -c:a pcm_s16le "$gap"
      echo "file '$gap'" >> "$concat_list"
      index=$((index + 1))
    done
  done
  echo '' >> "$json"; echo ']}' >> "$json"

  ffmpeg -y -loglevel error -f concat -safe 0 -i "$concat_list" -c:a pcm_s16le \
    "$OUT_DIR/${name}.wav"
  echo "built $OUT_DIR/${name}.wav + ${name}.json ($(afinfo "$OUT_DIR/${name}.wav" | awk '/estimated duration/ {print $3}')s)"
}

build_clip "two_speakers_short" 1
build_clip "two_speakers_long" 3

echo "OK: verification audio in $OUT_DIR"
