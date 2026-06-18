#!/usr/bin/env bash
# Build Visor.app and publish it as the latest GitHub release asset, so both
# the in-app "Update Visor" button and the curl installer deliver current main.
#
#   ./scripts/release.sh            # refresh the default tag's asset
#   ./scripts/release.sh v0.2.0     # cut a new tagged release
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="${VISOR_REPO_SLUG:-sanketsriv22/visor}"
TAG="${1:-v0.1.0}"

"$REPO_DIR/scripts/make-app.sh"
ditto -c -k --keepParent "$REPO_DIR/dist/Visor.app" "$REPO_DIR/dist/Visor.zip"

if gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$REPO_DIR/dist/Visor.zip" --repo "$SLUG" --clobber
else
  gh release create "$TAG" "$REPO_DIR/dist/Visor.zip" --repo "$SLUG" \
    --title "Visor $TAG" --notes "Prebuilt Visor.app (Apple Silicon)."
fi
echo "Published $TAG to $SLUG — the Update button and installer now serve this build."
