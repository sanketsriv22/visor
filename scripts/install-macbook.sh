#!/bin/bash
# Install a CI build on the MacBook without killing a dictation.
#
#   scripts/install-macbook.sh <Visor.zip>
#
# Stages the app in /tmp/visor-staged on the MacBook and leaves a note for
# the running Visor, which asks the user — Install now / Not now — once
# nothing is in flight, then swaps the bundle and relaunches itself. If
# Visor isn't running, installs directly. If the running build predates
# the in-app updater, falls back to a dialog raised in the GUI session.
set -euo pipefail
HOST="${VISOR_HOST:-100.101.123.108}"
ZIP="$1"

scp -q -o ConnectTimeout=15 "$ZIP" "$HOST:/tmp/Visor.zip"
ssh -o ConnectTimeout=15 "$HOST" bash -s <<'REMOTE'
set -e
rm -rf /tmp/visor-staged && mkdir -p /tmp/visor-staged
ditto -xk /tmp/Visor.zip /tmp/visor-staged
APP=$(find /tmp/visor-staged -name Visor.app -maxdepth 3 | head -1)
BUILD=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "?")
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
SUPPORT="$HOME/Library/Application Support/Visor"
mkdir -p "$SUPPORT"
rm -f "$SUPPORT/update-result"

INSTALLED=$(defaults read /Applications/Visor.app/Contents/Info.plist CFBundleVersion 2>/dev/null || echo 0)
if pgrep -x Visor >/dev/null && [ "${INSTALLED:-0}" -lt 471 ]; then
  # Before the in-app updater: macOS refuses a dialog from SSH, so the
  # best we can do is never replace mid-dictation. Idle = the trace's last
  # line is a delivery, cancel or failure, or is older than 20 s.
  LOG="$HOME/Library/Logs/Visor/dictation.log"
  for i in $(seq 1 60); do
    last=$(tail -1 "$LOG" 2>/dev/null || true)
    age=$(( $(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%S" "${last:0:19}" +%s 2>/dev/null || echo 0) ))
    case "$last" in
      *deliver:*|*cancel*|*FAILED*|*"finish: no file"*|"") break ;;
    esac
    [ "$age" -gt 20 ] && break
    sleep 2
  done
  killall -9 Visor 2>/dev/null || true; sleep 2
  rm -rf /Applications/Visor.app; ditto "$APP" /Applications/Visor.app
  open -n /Applications/Visor.app; sleep 2
  echo "installed build $BUILD over pre-updater build $INSTALLED when idle; running: $(pgrep -x Visor | wc -l | tr -d ' ')"
  exit 0
fi

if ! pgrep -x Visor >/dev/null; then
  rm -rf /Applications/Visor.app
  ditto "$APP" /Applications/Visor.app
  open -n /Applications/Visor.app
  sleep 2
  echo "installed build $BUILD (Visor was not running)"
  exit 0
fi

# Leave the note; the running app asks when idle.
printf '{"path":"%s","build":"%s"}' "$APP" "$BUILD" > "$SUPPORT/update-ready.json"
for i in $(seq 1 90); do
  if [ -f "$SUPPORT/update-result" ]; then
    r=$(cat "$SUPPORT/update-result")
    case "$r" in
      installed) sleep 3; echo "installed build $BUILD — user chose Install; running: $(pgrep -x Visor | wc -l | tr -d ' ')"; exit 0 ;;
      declined)  echo "build $BUILD staged; user chose Not now — "Install build N" waits in the menu-bar panel, and it asks again at next launch"; exit 0 ;;
      failed)    echo "build $BUILD: the in-app install failed"; exit 1 ;;
    esac
  fi
  sleep 2
done

echo "build $BUILD staged; no answer from the app in three minutes — note left, it will ask when idle"
REMOTE
