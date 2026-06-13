#!/usr/bin/env bash
# Install Visor from source.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/visor/main/install.sh | bash
#
# Clones (or updates) the repo, builds the app, and installs it to
# /Applications via scripts/make-app.sh.
#
# Requirements: git and a Swift toolchain (`xcode-select --install`).
# Override the source repo with VISOR_REPO, or the checkout dir with VISOR_SRC.
set -euo pipefail

REPO_URL="${VISOR_REPO:-https://github.com/sanketsriv22/visor.git}"
SRC="${VISOR_SRC:-$HOME/.visor/src}"

command -v git >/dev/null   || { echo "git is required" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift toolchain required — run: xcode-select --install" >&2; exit 1; }

if [ -d "$SRC/.git" ]; then
  echo "Updating $SRC …"
  git -C "$SRC" pull --ff-only
else
  echo "Cloning $REPO_URL …"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 "$REPO_URL" "$SRC"
fi

bash "$SRC/scripts/make-app.sh"
open /Applications/Visor.app
echo "Visor installed. Move your cursor to the notch and click."
