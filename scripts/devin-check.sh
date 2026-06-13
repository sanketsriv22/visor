#!/usr/bin/env bash
# Review the sticky note and act on stale tasks using the *local* Devin CLI
# (https://docs.devin.ai/cli). The CLI reads your notes straight off disk, so
# no API key, private repo, or git sync is required — just `devin auth login`
# once. Schedule this with launchd/cron (see com.user.devin-check.plist).
#
# Env knobs:
#   VISOR_HOURS=24            tasks at least this old count as "stale"
#   VISOR_AUTONOMOUS=1        let Devin actually DO tasks (--permission-mode
#                             dangerous) instead of only reminding. Runs in
#                             VISOR_WORK_DIR, so point that at the repo you
#                             want it to touch.
#   VISOR_WORK_DIR=~/repos    working directory for the Devin session
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MCP="$REPO/mcp-server/dist/index.js"
NOTES="${STICKY_NOTES_FILE:-$HOME/StickyNotes/sticky.md}"
HOURS="${VISOR_HOURS:-24}"
WORK_DIR="${VISOR_WORK_DIR:-$HOME/repos}"
export PATH="$HOME/.local/bin:$PATH"

# 1. Pull stale open tasks as JSON (this also refreshes first-seen stamps).
STALE="$(node "$MCP" --stale "$HOURS")"
COUNT="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch{console.log(0)}})' <<<"$STALE")"

if [ "$COUNT" -eq 0 ]; then
  echo "$(date '+%F %T') — no tasks older than ${HOURS}h, nothing to do."
  exit 0
fi

# 2. Instant local nudge, independent of whatever Devin decides to do.
TITLES="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const t of JSON.parse(s))console.log("• "+t.text+" ("+t.ageHours+"h)")})' <<<"$STALE")"
osascript -e "display notification \"${TITLES//\"/\\\"}\" with title \"Visor: ${COUNT} stale task(s)\"" 2>/dev/null || true

# 3. Hand the same list to Devin to act on / send a richer reminder.
read -r -d '' PROMPT <<EOF || true
These are my stale sticky-note tasks (open for at least ${HOURS}h), as JSON:

${STALE}

My full sticky note is at ${NOTES} ('- [ ]' = open, '- [x]' = done).
For each stale task: if it is a coding, research, or chore task you can do
yourself, start doing it and report what you took on. Otherwise treat it as a
reminder. If a Slack MCP/integration is available to you, send me a short Slack
message summarizing the stale tasks and anything you started. End your reply
with one line beginning "SUMMARY:" describing what you did.
EOF

MODE="auto"
CD_DIR="$HOME"
if [ "${VISOR_AUTONOMOUS:-}" = "1" ]; then
  MODE="dangerous"
  CD_DIR="$WORK_DIR"
fi

cd "$CD_DIR"
devin --permission-mode "$MODE" -p "$PROMPT"
