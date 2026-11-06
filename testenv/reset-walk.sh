#!/bin/bash
# Between walks: quit the app, restore the vault, empty the app's data folder (sessions and both stand-in sign-in flags)
# and the stand-in logs. The tester then runs launch-app.sh again.
set -u
osascript -e 'tell application id "com.clickyfork.app" to quit' >/dev/null 2>&1 || true
sleep 1
bash /Users/admin/reset-vault.sh
bash /Users/admin/reset-brain.sh
rm -rf /Users/admin/clicky-data /Users/admin/standin-log
mkdir -p /Users/admin/clicky-data /Users/admin/standin-log
echo "reset done: vault and brain fixture restored, clicky-data and standin-log emptied"
