#!/bin/bash
# Fixtures in the image: executable stand-ins and driver, the fixture vault (plus a reset script), empty data and log folders.
set -euo pipefail
chmod +x /Users/admin/standin/claude /Users/admin/standin/codex /Users/admin/testenv-driver/clicky-driver \
  /Users/admin/launch-app.sh /Users/admin/reset-walk.sh /Users/admin/fixture-vault/*.sh
mv /Users/admin/fixture-vault/reset-vault.sh /Users/admin/reset-vault.sh
bash /Users/admin/reset-vault.sh
mkdir -p /Users/admin/clicky-data /Users/admin/standin-log
# Self-checks: each stand-in answers, and the driver starts (exit 64 is its usage exit) under the testenv exec PATH.
exec_path="/bin:/usr/bin:/usr/sbin:/usr/local/bin:/opt/homebrew/bin"
env -i PATH="$exec_path" HOME="$HOME" STANDIN_LOG_DIR=/tmp/standin-selfcheck /Users/admin/standin/claude --version
env -i PATH="$exec_path" HOME="$HOME" STANDIN_LOG_DIR=/tmp/standin-selfcheck /Users/admin/standin/codex --version
rm -rf /tmp/standin-selfcheck
rc=0; /Users/admin/testenv-driver/clicky-driver bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || { echo "fixtures.sh: driver did not exit 64 on bad usage (got $rc)" >&2; exit 1; }
