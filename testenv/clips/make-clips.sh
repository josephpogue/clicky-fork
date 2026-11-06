#!/bin/bash
# make-clips.sh <output dir>: one 48 kHz mono WAV per clips/<id>.txt, spoken by `say`. The .txt sidecar holds the exact words.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?output dir}"; mkdir -p "$out"
for sidecar in "$here"/*.txt; do
  id="$(basename "$sidecar" .txt)"
  say -v Samantha -o "$out/$id.aiff" -f "$sidecar"
  afconvert -f WAVE -d LEI16@48000 -c 1 "$out/$id.aiff" "$out/$id.wav"; rm "$out/$id.aiff"
  cp "$sidecar" "$out/$id.txt"
done
