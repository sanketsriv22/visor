#!/usr/bin/env bash
# Build Visor.app, sign the archive with Sparkle EdDSA, publish a GitHub release,
# and update the Sparkle appcast so existing installs pick up the new version.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="${VISOR_REPO_SLUG:-sanketsriv22/visor}"
VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
# Sparkle compares the appcast's sparkle:version against the app's
# CFBundleVersion. make-app.sh bakes CFBundleVersion = git commit count, so the
# appcast MUST use that same integer here — not the marketing string, or the
# comparison breaks (e.g. "1.0-beta.29" reads as version 1, which looks older
# than the installed build number, so updates are never offered).
BUILD="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
TAG="v$VERSION"
TOOLS="$REPO_DIR/.sparkle-tools"
SIGN_TOOL="$TOOLS/sign_update"

# ── Flags ────────────────────────────────────────────────────────────────
#   --no-bump : release the current VERSION but do NOT advance it afterwards
#               (use when you want to hand-pick the next version, e.g. 1.0).
#   --force   : re-publish a VERSION that's already released (skip the guard).
BUMP_AFTER=1
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-bump) BUMP_AFTER=0 ;;
    --force)   FORCE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ── Guard: never cut the same version twice ──────────────────────────────
# If a tag/release for this VERSION already exists, someone forgot to bump it.
# Re-releasing the same marketing version differs only by build number, which
# is confusing ("beta.32 (106) available — you have beta.32 (104)").
if [ "$FORCE" != "1" ]; then
  if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
     || git -C "$REPO_DIR" ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 \
     || gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
    echo "ERROR: $TAG is already released. Bump VERSION (currently $VERSION) and add a" >&2
    echo "       CHANGELOG.md entry for the new version before cutting a release." >&2
    echo "       (Pass --force only to deliberately re-publish the same version.)" >&2
    exit 1
  fi
fi

# ── 1. Ensure Sparkle CLI tools are available ────────────────────────────
if [ ! -x "$SIGN_TOOL" ]; then
  echo "Downloading Sparkle CLI tools…"
  mkdir -p "$TOOLS"
  SPARKLE_VER="2.7.5"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz" \
    | tar -xJ -C "$TOOLS" bin/sign_update bin/generate_keys 2>/dev/null \
    || tar -xJ -C "$TOOLS" --include='*/sign_update' --include='*/generate_keys' \
         < <(curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz")
  # The tools may land in bin/ or directly — normalise.
  [ -f "$TOOLS/bin/sign_update" ] && mv "$TOOLS/bin/"* "$TOOLS/" && rmdir "$TOOLS/bin" 2>/dev/null || true
  chmod +x "$TOOLS/sign_update" "$TOOLS/generate_keys" 2>/dev/null || true
fi

# ── 2. Build ─────────────────────────────────────────────────────────────
"$REPO_DIR/scripts/make-app.sh" --build-only
ditto -c -k --keepParent "$REPO_DIR/dist/Visor.app" "$REPO_DIR/dist/Visor.zip"

# ── 3. Sign the archive ─────────────────────────────────────────────────
SIG_OUTPUT=$("$SIGN_TOOL" "$REPO_DIR/dist/Visor.zip" 2>&1) || {
  echo "ERROR: sign_update failed. Run '$TOOLS/generate_keys' first to create an EdDSA key pair."
  exit 1
}
ED_SIG=$(echo "$SIG_OUTPUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(wc -c < "$REPO_DIR/dist/Visor.zip" | tr -d ' ')
PUBDATE=$(date -R)

# ── 4. Changelog ─────────────────────────────────────────────────────────
awk -v v="$VERSION" '
  index($0, "## " v) == 1 { f=1; next }
  f && /^## / { exit }
  f { print }
' "$REPO_DIR/CHANGELOG.md" > /tmp/visor-notes.md
[ -s /tmp/visor-notes.md ] || echo "See CHANGELOG.md" > /tmp/visor-notes.md

# ── 5. Generate appcast.xml ──────────────────────────────────────────────
DOWNLOAD_URL="https://github.com/$SLUG/releases/download/$TAG/Visor.zip"
cat > "$REPO_DIR/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Visor Updates</title>
        <link>https://github.com/$SLUG/releases</link>
        <item>
            <title>Visor $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <enclosure
                url="$DOWNLOAD_URL"
                sparkle:edSignature="$ED_SIG"
                length="$LENGTH"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
XML

# ── 6. Publish GitHub release ────────────────────────────────────────────
if gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$REPO_DIR/dist/Visor.zip" --repo "$SLUG" --clobber
  gh release edit "$TAG" --repo "$SLUG" --title "Visor $VERSION" --notes-file /tmp/visor-notes.md --latest
else
  gh release create "$TAG" "$REPO_DIR/dist/Visor.zip" --repo "$SLUG" \
    --title "Visor $VERSION" --notes-file /tmp/visor-notes.md --latest
fi

# ── 7. Commit and push appcast ───────────────────────────────────────────
git -C "$REPO_DIR" add appcast.xml
git -C "$REPO_DIR" diff --cached --quiet appcast.xml || \
  git -C "$REPO_DIR" commit -m "Update appcast for $VERSION"
git -C "$REPO_DIR" push origin HEAD

echo "Published $TAG to $SLUG."

# ── 8. Advance VERSION for the next cycle ────────────────────────────────
# Bump the trailing number (e.g. 1.0-beta.32 -> 1.0-beta.33) and commit, so the
# next release is always a fresh number and the guard above can't trip on a
# stale VERSION. Add the matching "## <new-version>" CHANGELOG entry as you work.
if [ "$BUMP_AFTER" = "1" ]; then
  if printf '%s' "$VERSION" | grep -qE '[0-9]+$'; then
    PREFIX="$(printf '%s' "$VERSION" | sed -E 's/[0-9]+$//')"
    NUM="$(printf '%s' "$VERSION" | grep -oE '[0-9]+$')"
    NEXT="${PREFIX}$((NUM + 1))"
    printf '%s\n' "$NEXT" > "$REPO_DIR/VERSION"
    git -C "$REPO_DIR" add VERSION
    git -C "$REPO_DIR" commit -m "Bump VERSION to $NEXT after releasing $VERSION"
    git -C "$REPO_DIR" push origin HEAD
    echo "VERSION advanced to $NEXT for the next cycle."
  else
    echo "note: VERSION ('$VERSION') has no trailing number to auto-bump — set the next one by hand." >&2
  fi
fi
