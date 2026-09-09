#!/usr/bin/env bash
# Build Visor.app (into dist/) and install it to /Applications.
# Re-run after any code change to update the installed app.
#
# Pass --build-only (or run in CI, where $CI is set) to just build dist/Visor.app
# without installing to /Applications — used by the release workflow.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/Visor.app"
VERSION="$(tr -d '[:space:]' < "$REPO/VERSION" 2>/dev/null)"
[ -n "$VERSION" ] || VERSION="0.0.0"
BUILD="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo "0")"

# Read the Sparkle EdDSA public key if it has been generated.
SPARKLE_KEY_FILE="$REPO/.sparkle-keys/ed25519-public.pem"
if [ -f "$SPARKLE_KEY_FILE" ]; then
    SU_PUBLIC_ED_KEY="$(tr -d '[:space:]' < "$SPARKLE_KEY_FILE")"
else
    SU_PUBLIC_ED_KEY=""
fi

BUILD_ONLY=""
[ "${1:-}" = "--build-only" ] && BUILD_ONLY=1
[ -n "${CI:-}" ] && BUILD_ONLY=1

cd "$REPO/app"
# Universal by default: a release built only on an Apple Silicon runner won't
# launch on an Intel Mac at all, and macOS fails that silently rather than
# saying why. Set VISOR_ARCHS=native for a single-slice build when iterating
# locally — it's noticeably faster.
# A universal build shells out to xcbuild, which only ships with Xcode.
# Command Line Tools alone can build a single architecture perfectly well, so
# fall back rather than fail — but say so loudly, because an arm64-only bundle
# will not launch on an Intel Mac and macOS reports that as nothing happening.
# Test the capability, not a path: xcbuild lives inside Xcode.app on a runner
# with Xcode selected and under /Library/Developer with Command Line Tools, so
# checking one hardcoded location made CI silently fall back to a single-arch
# build. This is the exact lookup that fails without Xcode.
WANT_UNIVERSAL=1
[ "${VISOR_ARCHS:-universal}" = "native" ] && WANT_UNIVERSAL=0
if [ "$WANT_UNIVERSAL" = "1" ] && ! xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    echo "warning: no Xcode found (xcbuild missing) — building for this machine only." >&2
    echo "         The result is NOT suitable for release; CI produces the universal build." >&2
    WANT_UNIVERSAL=0
fi

if [ "$WANT_UNIVERSAL" = "0" ]; then
    swift build -c release
    BIN=".build/release/Visor"
else
    swift build -c release --arch arm64 --arch x86_64
    # A multi-arch build lands under .build/apple/Products, not .build/release.
    BIN="$(find .build/apple/Products/Release -maxdepth 1 -name Visor -type f 2>/dev/null | head -1)"
    [ -n "$BIN" ] || BIN=".build/release/Visor"
fi

rm -rf "$REPO/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Visor"
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/Visor" 2>/dev/null)"

# Embed Sparkle.framework so the app can find it at runtime.
SPARKLE_FW=$(find .build -path '*/Sparkle.framework' -type d -maxdepth 6 | head -1)
if [ -n "$SPARKLE_FW" ]; then
    ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Visor" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Visor</string>
    <key>CFBundleIdentifier</key><string>com.kitalabs.visor</string>
    <key>CFBundleName</key><string>Visor</string>
    <key>CFBundleDisplayName</key><string>Visor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <!-- Dictation records from the mic; macOS refuses access without a reason
         string, and the app is killed on first use if this is missing. -->
    <key>NSMicrophoneUsageDescription</key><string>Visor records your voice so you can dictate into the composer.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Visor reads the chess board straight out of your browser's page, which needs permission to talk to it.</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/sanketsriv22/visor/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.kitalabs.visor.beam</string>
            <key>CFBundleURLSchemes</key>
            <array><string>visor</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Visor Note</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array><string>com.kitalabs.visor.note</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.kitalabs.visor.note</string>
            <key>UTTypeDescription</key><string>Visor Note</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>visor</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# App icon: use the committed .icns (so CI needs no GUI). To regenerate it from
# scripts/AppIcon-1024.png, see scripts/make-appicon.swift.
if [ -f "$REPO/scripts/AppIcon.icns" ]; then
    cp "$REPO/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: scripts/AppIcon.icns missing, building without icon" >&2
fi

# Template images (macOS auto-colorises via alpha channel): the menu-bar icon
# and the in-app trefoil "beam" glyph. Loaded by NSImage(named:).
for f in "$REPO/app/Sources/Visor/Resources"/*Template*.png; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done

# Bundled fonts (registered at launch via CTFontManager). Departure Mono is the
# Settings type face.
for f in "$REPO/app/Sources/Visor/Resources"/*.otf; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done
# The introduction's 3D mark, rendered in Blender as a sprite sheet, and the
# founder's welcome video if one has been recorded (Resources/intro.mp4).
for f in "$REPO/app/Sources/Visor/Resources"/hero-*.png "$REPO/app/Sources/Visor/Resources"/intro.mp4; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done

# The introduction's narration: the script, and the clips rendered from it
# by scripts/narration.py, one folder per bundled voice.
cp "$REPO/app/Sources/Visor/Resources/narration.json" "$APP/Contents/Resources/"
if [ -d "$REPO/app/Sources/Visor/Resources/narration" ]; then
    cp -R "$REPO/app/Sources/Visor/Resources/narration" "$APP/Contents/Resources/narration"
fi

# Bundle the changelog so the app can show "What's New" offline.
cp "$REPO/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md" 2>/dev/null || true

# Firebase config for live note sharing. It's a secret (gitignored), so it lives
# outside the repo by default — override with GOOGLE_SERVICE_PLIST. Absent? The
# app still builds and runs; live sharing just stays disabled (FirebaseBootstrap
# no-ops without it).
GOOGLE_SERVICE_PLIST="${GOOGLE_SERVICE_PLIST:-$REPO/GoogleService-Info.plist}"
if [ -f "$GOOGLE_SERVICE_PLIST" ]; then
    cp "$GOOGLE_SERVICE_PLIST" "$APP/Contents/Resources/GoogleService-Info.plist"
else
    echo "warning: no GoogleService-Info.plist (looked at $GOOGLE_SERVICE_PLIST) — live note sharing disabled" >&2
fi

# Prefer a real Developer ID when the machine has one: TCC permissions and
# Keychain ACLs are bound to the signature, so an ad-hoc build is a different
# app to macOS every time it's rebuilt — which is what makes Accessibility and
# Keychain grants evaporate between builds. CI has no certificate, so it falls
# back to ad-hoc and scripts/sign-and-notarize.sh signs properly afterwards.
# `|| true` matters: with set -e and pipefail, grep finding nothing on a
# machine with no certificate (i.e. CI) fails the whole script.
SIGN_ID="${VISOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
if [ -n "$SIGN_ID" ] && [ -f "$REPO/app/Visor.entitlements" ]; then
    echo "signing with: $SIGN_ID"
    "$REPO/scripts/sign-and-notarize.sh" --skip-notarize
else
    echo "no Developer ID found — ad-hoc signing"
    codesign --force --sign - --deep "$APP"
fi

if [ -n "$BUILD_ONLY" ]; then
    echo "Built $APP (v${VERSION})"
    exit 0
fi

# Replace any running copy, then install
pkill -x Visor 2>/dev/null || true
if ! rm -rf /Applications/Visor.app 2>/dev/null; then
    osascript -e 'do shell script "rm -rf /Applications/Visor.app" with administrator privileges'
fi
ditto "$APP" /Applications/Visor.app
echo "Installed /Applications/Visor.app (v${VERSION})"
