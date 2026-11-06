#!/bin/bash
# Build the app for the test Mac. It is the normal build (scripts/build-app.sh); the last line printed is the app path.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
bash scripts/build-app.sh "$@"
