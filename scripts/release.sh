#!/usr/bin/env bash
# Build Visor.app and publish it as the release for the version in ./VERSION,
# with that version's CHANGELOG section as the release notes. Both the in-app
# "Update Visor" button and the curl installer fetch the latest release.
#
# Normally CI does this on every push to main; run this to publish from your
# machine. Bump ./VERSION and add a CHANGELOG entry to cut a new version.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="${VISOR_REPO_SLUG:-sanketsriv22/visor}"
VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
TAG="v$VERSION"

"$REPO_DIR/scripts/make-app.sh" --build-only
ditto -c -k --keepParent "$REPO_DIR/dist/Visor.app" "$REPO_DIR/dist/Visor.zip"

awk -v v="$VERSION" '
  index($0, "## " v) == 1 { f=1; next }
  f && /^## / { exit }
  f { print }
' "$REPO_DIR/CHANGELOG.md" > /tmp/visor-notes.md
[ -s /tmp/visor-notes.md ] || echo "See CHANGELOG.md" > /tmp/visor-notes.md

if gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$REPO_DIR/dist/Visor.zip" --repo "$SLUG" --clobber
  gh release edit "$TAG" --repo "$SLUG" --title "Visor $VERSION" --notes-file /tmp/visor-notes.md --latest
else
  gh release create "$TAG" "$REPO_DIR/dist/Visor.zip" --repo "$SLUG" \
    --title "Visor $VERSION" --notes-file /tmp/visor-notes.md --latest
fi
echo "Published $TAG to $SLUG."
