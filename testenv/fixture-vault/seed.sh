#!/bin/bash
# seed.sh <vault dir>: make the fixture notes folder: a git repo with three project pages, each with an H1.
set -euo pipefail
vault="${1:?vault dir}"
rm -rf "$vault"; mkdir -p "$vault/Wiki/Projects"
printf '# Clicky Fork\n\nA menu-bar helper that answers questions about the screen.\n' > "$vault/Wiki/Projects/clicky-fork.md"
printf '# Homelab\n\nNotes on the lab machines.\n' > "$vault/Wiki/Projects/homelab.md"
printf '# Meetily Fork\n\nMeeting notes assistant.\n' > "$vault/Wiki/Projects/meetily-fork.md"
cd "$vault"
git init -q -b main
git -c user.name=Fixture -c user.email=fixture@example.com add -A
git -c user.name=Fixture -c user.email=fixture@example.com commit -q -m "Fixture vault"
