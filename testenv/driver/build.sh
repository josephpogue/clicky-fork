#!/bin/bash
# Build the driver on the host: build.sh <output dir>. Makes <output dir>/clicky-driver (arm64, ad-hoc signed).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?output dir}"; mkdir -p "$out"
swiftc -O -target arm64-apple-macos14.0 "$here/main.swift" -o "$out/clicky-driver"
codesign --force --sign - "$out/clicky-driver"
