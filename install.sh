#!/bin/bash
# Installs LiteBrowser with Homebrew straight from this folder (no GitHub needed).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

command -v brew >/dev/null || { echo "Homebrew not found. Install it from https://brew.sh first."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Installing Xcode Command Line Tools (needed for swiftc)…"; xcode-select --install; echo "Re-run ./install.sh when that finishes."; exit 1; }

VERSION=1.0.0
mkdir -p dist
TARBALL="$ROOT/dist/lite-browser-$VERSION.tar.gz"
tar -czf "$TARBALL" Sources Resources Info.plist Makefile litebrowser LICENSE
SHA=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
URL="file://${TARBALL// /%20}"

TAP=litebrowser/local
brew tap-new --no-git "$TAP" >/dev/null 2>&1 || true
TAP_DIR="$(brew --repository "$TAP")"
mkdir -p "$TAP_DIR/Formula"
sed -e "s#^  url .*#  url \"$URL\"#" \
    -e "s#^  sha256 .*#  sha256 \"$SHA\"#" \
    -e '/^  head /d' \
    Formula/lite-browser.rb > "$TAP_DIR/Formula/lite-browser.rb"

if brew list --formula "$TAP/lite-browser" >/dev/null 2>&1; then
  brew reinstall "$TAP/lite-browser"
else
  brew install "$TAP/lite-browser"
fi

ln -sfn "$(brew --prefix lite-browser)/LiteBrowser.app" /Applications/LiteBrowser.app 2>/dev/null \
  && echo "Linked into /Applications." || true
echo
touch /Applications/LiteBrowser.app 2>/dev/null || true   # refresh Dock/Finder icon
echo "Done. Start it with:  litebrowser"
