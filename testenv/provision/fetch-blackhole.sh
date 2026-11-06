#!/bin/bash
# fetch-blackhole.sh <output dir>: on the host, download the BlackHole 2ch and 16ch installer packages through Homebrew's
# cask metadata (so the version and checksum are Homebrew's) and copy them out as BlackHole2ch.pkg and BlackHole16ch.pkg.
set -euo pipefail
out="${1:?output dir}"; mkdir -p "$out"
eval "$(/opt/homebrew/bin/brew shellenv)"
HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --cask blackhole-2ch blackhole-16ch >&2
cache="$(brew --cache)/downloads"
for name in BlackHole2ch BlackHole16ch; do
  pkg=$(ls -t "$cache"/*--"$name"-*.pkg | head -1)
  cp "$pkg" "$out/$name.pkg"
done
