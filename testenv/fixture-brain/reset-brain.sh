#!/bin/bash
# Restore /Users/admin/brain-fixture and /Users/admin/outside-secret.md to the fixture.
set -euo pipefail
bash /Users/admin/fixture-brain/seed.sh /Users/admin/brain-fixture /Users/admin/outside-secret.md
echo "brain restored: $(find /Users/admin/brain-fixture -type f -o -type l | wc -l | tr -d ' ') files and links under /Users/admin/brain-fixture, outside file in place"
