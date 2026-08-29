#!/usr/bin/env bash
# Sign dist/Visor.app with Developer ID, notarize it, staple the ticket, and
# optionally build a DMG.
#
#   ./scripts/sign-and-notarize.sh [--dmg] [--skip-notarize]
#
# Needs a "Developer ID Application" identity in the keychain, and (unless
# --skip-notarize) a stored notarytool profile:
#
#   xcrun notarytool store-credentials "visor-notary" \
#     --apple-id <id> --team-id <team> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
APP="$REPO/dist/Visor.app"
ENTITLEMENTS="$REPO/app/Visor.entitlements"
PROFILE="${VISOR_NOTARY_PROFILE:-visor-notary}"

DMG=0; NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --dmg) DMG=1 ;;
    --skip-notarize) NOTARIZE=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/make-app.sh first" >&2; exit 1; }

IDENTITY="${VISOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"
[ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity in the keychain" >&2; exit 1; }
echo "signing as: $IDENTITY"

# --- 1. Sign inside-out ----------------------------------------------------
# Nested code must be signed before whatever contains it: signing the outer
# bundle seals a hash of its contents, so re-signing anything inside afterwards
# invalidates the outer signature. Ad-hoc signing let us ignore this; Developer
# ID and notarization do not.
sign() {
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"
}

# Deepest paths first, so children are always signed before their parents.
find "$APP/Contents/Frameworks" \
  \( -name "*.xpc" -o -name "*.app" -o -name "*.dylib" -o -name "*.framework" \) \
  -maxdepth 4 2>/dev/null | awk '{ print length"\t"$0 }' | sort -rn | cut -f2- | while read -r item; do
    echo "  signing $(basename "$item")"
    sign "$item" 2>/dev/null || sign "$item"
done

# Sparkle's helper binaries aren't bundles, so the find above misses them.
for helper in "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" \
              "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app"; do
  [ -e "$helper" ] && { echo "  signing $(basename "$helper")"; sign "$helper"; }
done

echo "  signing Visor.app"
sign --entitlements "$ENTITLEMENTS" "$APP"

echo "=== verifying ==="
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 2. Notarize -----------------------------------------------------------
ZIP="$REPO/dist/Visor-notarize.zip"
if [ "$NOTARIZE" = "1" ]; then
  # ditto, not zip: the bundle's symlinks have to survive the round trip.
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "=== submitting to Apple (this takes a few minutes) ==="
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  # Stapling attaches the ticket to the app so it validates offline.
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
  echo "notarized and stapled."
else
  echo "skipping notarization (--skip-notarize)"
fi

# --- 3. DMG ----------------------------------------------------------------
if [ "$DMG" = "1" ]; then
  VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
  STAGE="$REPO/dist/dmg"
  DMG_PATH="$REPO/dist/Visor-$VERSION.dmg"
  rm -rf "$STAGE" "$DMG_PATH"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Visor.app"
  # The Applications symlink is what makes the window a drag-to-install.
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Visor" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  # The DMG is signed and notarized in its own right, so Gatekeeper is happy
  # with the container as well as what's inside it.
  codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
  if [ "$NOTARIZE" = "1" ]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
  fi
  echo "wrote $DMG_PATH"
fi
