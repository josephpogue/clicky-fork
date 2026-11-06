#!/bin/bash
# Restore /Users/admin/vault to the fixture: three project pages, one commit, nothing else.
set -euo pipefail
bash /Users/admin/fixture-vault/seed.sh /Users/admin/vault
echo "vault restored: $(git -C /Users/admin/vault log --oneline | wc -l | tr -d ' ') commit, $(ls /Users/admin/vault/Wiki/Projects | wc -l | tr -d ' ') project pages"
