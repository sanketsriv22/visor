#!/usr/bin/env bash
# Send your current open sticky-note tasks to Devin, on demand.
#
# Default: opens an INTERACTIVE Devin session (in VISOR_WORK_DIR) seeded with
# your tasks, so you can watch and steer it.
# With --print (or VISOR_PRINT=1): non-interactive — Devin processes the tasks,
# prints a summary, and exits. Good for "just tell me what's left".
#
# Env knobs:
#   VISOR_WORK_DIR=~/repos     directory the interactive session runs in
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MCP="$REPO/mcp-server/dist/index.js"
export PATH="$HOME/.local/bin:$PATH"

TASKS="$(node "$MCP" --list)"
COUNT="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch{console.log(0)}})' <<<"$TASKS")"
if [ "$COUNT" -eq 0 ]; then
  echo "No open tasks on your sticky — nothing to send."
  exit 0
fi

read -r -d '' PROMPT <<EOF || true
These are my open sticky-note tasks, as JSON:

${TASKS}

Work through them: for each task, either do it (if it's a coding, research, or
chore task you can handle) or tell me exactly what you need from me. Start with
the most actionable. If you finish one, say so clearly so I can check it off.
EOF

if [ "${VISOR_PRINT:-}" = "1" ] || [ "${1:-}" = "--print" ]; then
  devin --permission-mode dangerous -p "$PROMPT"
else
  cd "${VISOR_WORK_DIR:-$HOME/repos}"
  devin "$PROMPT"
fi
