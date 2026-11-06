#!/bin/bash
# seed.sh <brain dir> <outside file>: make the fixture brain (invented notes) and, outside it, the file a symlink points at.
#   Wiki/Projects/demo-server.md   the port the walk looks for (4417)
#   Wiki/Projects/release.md       deploys and test builds
#   Wiki/index.md                  a map of both pages
#   projects/demo-app/             a code folder: .git/ (must never be searched), README.md, .env (secret, never readable),
#                                  link-out.md (a symlink to the outside file, must never be followed)
set -euo pipefail
brain="${1:?brain dir}"
outside="${2:?outside file}"
rm -rf "$brain" "$outside"
mkdir -p "$brain/Wiki/Projects" "$brain/projects/demo-app/.git"
printf '# Demo server\n\n## Ports\nThe demo server listens on port 4417 behind the lab proxy.\n' > "$brain/Wiki/Projects/demo-server.md"
printf '# Release\n\n## Deploys\nDeploys go through the release script, run from the top of the repo.\n\n## Builds\nTest builds use Release, never Debug.\n' > "$brain/Wiki/Projects/release.md"
printf '# Index\n\nA map of the notes.\n\n- [Demo server](Projects/demo-server.md)\n- [Release](Projects/release.md)\n' > "$brain/Wiki/index.md"
printf '# Demo app\n\nA tiny app used only by the test fixture.\n' > "$brain/projects/demo-app/README.md"
printf 'SENTINEL_SECRET=never-shown-8812\n' > "$brain/projects/demo-app/.env"
# Git's own files: the search must skip this folder, so this marker never shows up in an answer.
printf 'ref: refs/heads/main\n' > "$brain/projects/demo-app/.git/HEAD"
printf '[core]\n\tnote = GITDIR-MARKER-2290\n' > "$brain/projects/demo-app/.git/config"
printf 'OUTSIDE-SENTINEL-5531\n' > "$outside"
ln -s "$outside" "$brain/projects/demo-app/link-out.md"
