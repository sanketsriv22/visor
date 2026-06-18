#!/usr/bin/env bash
# Build Visor.app and install it to /Applications.
# Re-run after any code change to update the installed app.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/Visor.app"
VERSION="0.1.0"

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
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# App icon: render a 1024pt master, then build the .icns
if swift "$REPO/scripts/render-icon.swift" /tmp/visor-icon-1024.png; then
    ICONSET=/tmp/Visor.iconset
    rm -rf "$ICONSET" && mkdir "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" /tmp/visor-icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s * 2))" "$((s * 2))" /tmp/visor-icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: icon generation failed, installing without icon" >&2
fi

codesign --force --sign - "$APP"

# Replace any running copy, then install
pkill -x Visor 2>/dev/null || true
rm -rf /Applications/Visor.app
ditto "$APP" /Applications/Visor.app
echo "Installed /Applications/Visor.app (v${VERSION})"
