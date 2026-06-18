#!/usr/bin/env bash
# Install Visor.
#
#   curl -fsSL https://raw.githubusercontent.com/sanketsriv22/visor/main/install.sh | bash
#
# By default this DOWNLOADS the prebuilt Visor.app from the latest GitHub
# release and installs it to /Applications — no compiler or toolchain needed
# (Apple Silicon). If the download fails, or you set VISOR_FROM_SOURCE=1, it
# falls back to cloning the repo and building with Swift.
set -euo pipefail

REPO="${VISOR_REPO_SLUG:-sanketsriv22/visor}"
APP="/Applications/Visor.app"
ZIP_URL="https://github.com/$REPO/releases/latest/download/Visor.zip"

install_app() { # $1 = path to a Visor.app
  pkill -x Visor 2>/dev/null || true
  rm -rf "$APP"
  ditto "$1" "$APP"
  # Downloaded apps are quarantined; clear it so Gatekeeper lets it open.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  open "$APP"
  echo "Visor installed to $APP. Move your cursor to the notch and click."
}

build_from_source() {
  command -v git >/dev/null   || { echo "git is required" >&2; exit 1; }
  command -v swift >/dev/null || { echo "Swift toolchain required — run: xcode-select --install" >&2; exit 1; }
  local src="${VISOR_SRC:-$HOME/.visor/src}"
  if [ -d "$src/.git" ]; then
    echo "Updating $src …"; git -C "$src" pull --ff-only
  else
    echo "Cloning https://github.com/$REPO …"
    mkdir -p "$(dirname "$src")"
    git clone --depth 1 "https://github.com/$REPO.git" "$src"
  fi
  bash "$src/scripts/make-app.sh"   # builds Visor.app and installs to /Applications
}

if [ "${VISOR_FROM_SOURCE:-}" = "1" ]; then
  build_from_source
  exit 0
fi

# Preferred path: download the prebuilt app.
tmp="$(mktemp -d)"
echo "Downloading Visor.app from the latest release …"
if curl -fsSL "$ZIP_URL" -o "$tmp/Visor.zip" && [ -s "$tmp/Visor.zip" ]; then
  ditto -x -k "$tmp/Visor.zip" "$tmp"
  if [ -d "$tmp/Visor.app" ]; then
    install_app "$tmp/Visor.app"
    exit 0
  fi
fi

echo "Prebuilt download unavailable — building from source instead." >&2
build_from_source
