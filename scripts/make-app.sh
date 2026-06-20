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
BUILD="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "0")"

BUILD_ONLY=""
[ "${1:-}" = "--build-only" ] && BUILD_ONLY=1
[ -n "${CI:-}" ] && BUILD_ONLY=1

cd "$REPO/app"
swift build -c release

rm -rf "$REPO/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Visor "$APP/Contents/MacOS/Visor"

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
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# App icon: use the committed .icns (so CI needs no GUI). Fall back to
# rendering one locally if it's missing.
if [ -f "$REPO/scripts/AppIcon.icns" ]; then
    cp "$REPO/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif swift "$REPO/scripts/render-icon.swift" /tmp/visor-icon-1024.png; then
    ICONSET=/tmp/Visor.iconset
    rm -rf "$ICONSET" && mkdir "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" /tmp/visor-icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s * 2))" "$((s * 2))" /tmp/visor-icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: icon generation failed, building without icon" >&2
fi

# Bundle the changelog so the app can show "What's New" offline.
cp "$REPO/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md" 2>/dev/null || true

codesign --force --sign - "$APP"

if [ -n "$BUILD_ONLY" ]; then
    echo "Built $APP (v${VERSION})"
    exit 0
fi

# Replace any running copy, then install
pkill -x Visor 2>/dev/null || true
mv /Applications/Visor.app "/tmp/visor-old-$$" 2>/dev/null || rm -rf /Applications/Visor.app
ditto "$APP" /Applications/Visor.app
echo "Installed /Applications/Visor.app (v${VERSION})"
