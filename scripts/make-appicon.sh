#!/usr/bin/env bash
# Regenerate AppIcon.icns from the brand mark. Run this only when the mark
# changes — the .icns is committed so CI builds need no GUI or source image.
#
#   ./scripts/make-appicon.sh [path/to/icon-1024.png]
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-$HOME/repos/kitalabs-website/public/icon-1024.png}"
[ -f "$SRC" ] || { echo "error: source not found: $SRC" >&2; exit 1; }

rm -rf AppIcon.iconset
swift make-appicon.swift "$SRC" AppIcon.iconset
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "wrote scripts/AppIcon.icns from $SRC"
