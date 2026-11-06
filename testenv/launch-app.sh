#!/bin/bash
# Start Clicky Fork in the test Mac. `open --env` hands the variables to the app itself and keeps the app its own
# responsible process for permissions. The stand-ins replace claude and codex; the vault and data folder are fixtures.
mkdir -p /Users/admin/clicky-data /Users/admin/standin-log
open --env CLICKY_CLAUDE_BIN=/Users/admin/standin/claude \
     --env CLICKY_CODEX_BIN=/Users/admin/standin/codex \
     --env CLICKY_VAULT_ROOT=/Users/admin/vault \
     --env CLICKY_DATA_DIR=/Users/admin/clicky-data \
     --env STANDIN_LOG_DIR=/Users/admin/standin-log \
     --stdout /tmp/testenv-app.log --stderr /tmp/testenv-app.log \
     -a "/Applications/Clicky Fork.app"
