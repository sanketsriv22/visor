#!/usr/bin/env bash
# Auto-commit and push ~/StickyNotes so cloud agents (Devin) can read it.
# One-time setup:
#   cd ~/StickyNotes && git init && gh repo create sticky-notes --private --source=. --push
# Then schedule this script every few minutes (see com.user.sticky-sync.plist).
set -euo pipefail

cd "${STICKY_DIR:-$HOME/StickyNotes}"
git add -A
git diff --cached --quiet && exit 0
git commit -qm "sticky sync $(date +%F-%H%M)"
git push -q
