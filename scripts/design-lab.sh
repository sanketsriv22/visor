#!/bin/bash
# Render the Design Lab on the MacBook that runs Visor and pull the captures
# back here.
#
#   scripts/design-lab.sh [out-dir] [--scenario <name>] [--theme <name|all>]
#
# Needs the CI build installed at /Applications/Visor.app on the MacBook and
# passwordless SSH to it. The lab runs as a second, short-lived instance next
# to the user's Visor and writes only under its own output folder.
set -euo pipefail

HOST="${VISOR_HOST:-100.101.123.108}"
OUT="${1:-$PWD/design-lab-out}"
[ $# -gt 0 ] && shift
REMOTE="/tmp/visor-design-lab"

echo "→ rendering on $HOST"
# shellcheck disable=SC2029
ssh "$HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE' && \
  open -n -W /Applications/Visor.app --args --design-lab '$REMOTE' $*"

mkdir -p "$OUT"
rm -rf "${OUT:?}"/*
scp -q -r "$HOST:$REMOTE/." "$OUT/"
echo "→ captures in $OUT"
cat "$OUT/log.txt" 2>/dev/null || true
