#!/bin/bash
# Two virtual audio devices, so the test Mac has a fake microphone and the speakers stay apart from it:
#   BlackHole 16ch = the fake microphone (default input). `testenv play <id> mic <clip>` writes the clip on channels 1-2
#                    and its inverse on 3-4, so a system-wide audio tap would hear silence while the app's microphone
#                    (channels 1-2) hears the clip at full level, as with a real microphone.
#   BlackHole 2ch  = the fake speakers (default output).
# The VM runs with --no-audio, so these are its only audio devices.
set -euo pipefail
eval "$(/opt/homebrew/bin/brew shellenv)"
# The build VM cannot reach the BlackHole download host (existential.audio times out from inside it), so the host
# fetches the two packages (`brew fetch`, build step in golden.pkr.hcl) and they are installed here from /Users/admin/blackhole.
sudo installer -pkg /Users/admin/blackhole/BlackHole2ch.pkg -target /
sudo installer -pkg /Users/admin/blackhole/BlackHole16ch.pkg -target /
# sox and switchaudio-osx install from the bottles the host fetched (fetch-audio-tools.sh), put into Homebrew's cache.
mkdir -p "$HOME/Library/Caches/Homebrew/downloads"
cp /Users/admin/brew-cache/downloads/* "$HOME/Library/Caches/Homebrew/downloads/"
# The host's formula metadata names the same versions as those bottles; a huge refresh interval keeps brew from replacing it.
rm -rf "$HOME/Library/Caches/Homebrew/api/internal"; mkdir -p "$HOME/Library/Caches/Homebrew/api"
cp -R /Users/admin/brew-cache/api/internal "$HOME/Library/Caches/Homebrew/api/internal"
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_API_AUTO_UPDATE_SECS=999999999 HOMEBREW_NO_ENV_HINTS=1 brew install sox switchaudio-osx
# The cask says "reboot to take effect", but restarting coreaudiod loads the new drivers (SIP is off in this image).
sudo killall coreaudiod || true
for _ in $(seq 1 30); do
  devices=$(SwitchAudioSource -a 2>/dev/null || true)
  if grep -qx "BlackHole 2ch" <<<"$devices" && grep -qx "BlackHole 16ch" <<<"$devices"; then found=1; break; fi
  sleep 1
done
if [ "${found:-0}" != 1 ]; then
  echo "audio.sh: BlackHole 2ch and 16ch not listed 30s after restarting coreaudiod; devices seen:" >&2
  echo "$devices" >&2
  exit 1
fi
SwitchAudioSource -t input -s "BlackHole 16ch"
SwitchAudioSource -t output -s "BlackHole 2ch"
SwitchAudioSource -t system -s "BlackHole 2ch"
SwitchAudioSource -c -t input; SwitchAudioSource -c -t output
