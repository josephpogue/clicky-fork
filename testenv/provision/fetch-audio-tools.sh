#!/bin/bash
# fetch-audio-tools.sh <output dir>: on the host, download the Homebrew bottles for sox and switchaudio-osx and their
# dependencies into <output dir>/downloads, laid out as Homebrew's download cache. The build VM's own internet is unreliable (some
# hosts, such as ghcr.io, time out from inside it), so audio.sh installs from these files.
set -euo pipefail
out="${1:?output dir}"; mkdir -p "$out/downloads" "$out/api"
eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
wanted=$(brew deps --union sox switchaudio-osx 2>/dev/null; echo sox; echo switchaudio-osx)
brew fetch --deps --bottle-tag=arm64_sequoia sox switchaudio-osx >&2
cache="$(brew --cache)/downloads"
for formula in $wanted; do
  # bottle files and bottle manifests are named <sha>--<formula>-<version>... or <sha>--<formula>--<version>...
  find "$cache" -maxdepth 1 -type f \( -name "*--$formula-[0-9]*" -o -name "*--$formula--[0-9]*" \) -exec cp {} "$out/downloads/" \;
done
# The formula metadata too: the build VM would otherwise use an older copy that names older versions than the bottles.
cp -R "$(brew --cache)/api/internal" "$out/api/internal"
ls "$out/downloads" | wc -l | tr -d ' ' | xargs -I{} echo "fetch-audio-tools: {} files" >&2
