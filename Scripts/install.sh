#!/bin/bash
# Installs or updates Pinwall from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/pinwall/main/Scripts/install.sh | bash
#
# Only uses what ships with macOS (curl, ditto, xattr, osascript): a fresh Mac has no
# working python3, and /usr/bin/python3 there is a stub that asks to install Xcode tools.
set -euo pipefail

REPO="bonkedbythonk/pinwall"
# A fixed asset name on every release, so the URL is known without the GitHub API (whose
# 60 anonymous requests an hour are shared by everyone behind the same IP).
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/Pinwall.zip"
INSTALL_DIR="${PINWALL_INSTALL_DIR:-/Applications}"
# For testing the script itself: PINWALL_ZIP=<local zip> skips the download,
# PINWALL_NO_OPEN=1 skips launching.

say() { printf '%s\n' "$*"; }

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${MACOS_MAJOR:-0}" -lt 15 ]; then
    say "Pinwall needs macOS 15 or later. This Mac runs $(sw_vers -productVersion)."
    exit 1
fi

# Standard (non-admin) accounts can't write /Applications. ~/Applications is where macOS
# puts per-user apps, and Spotlight finds them there too.
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    say "Installing to $INSTALL_DIR, since this account can't write to /Applications."
fi
APP="$INSTALL_DIR/Pinwall.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading Pinwall…"
if [ -n "${PINWALL_ZIP:-}" ]; then
    cp "$PINWALL_ZIP" "$TMP/Pinwall.zip"
elif ! curl -fL --progress-bar -o "$TMP/Pinwall.zip" "$DOWNLOAD_URL"; then
    say "The download didn't work. Check your connection, or get it by hand from"
    say "  https://github.com/$REPO/releases"
    exit 1
fi

ditto -x -k "$TMP/Pinwall.zip" "$TMP"
if [ ! -d "$TMP/Pinwall.app" ]; then
    say "The download doesn't contain Pinwall.app. Please report it at https://github.com/$REPO/issues"
    exit 1
fi

# Quit a running copy so the update can replace it.
if [ -z "${PINWALL_NO_OPEN:-}" ] && pgrep -xq Pinwall; then
    say "Quitting the running Pinwall…"
    osascript -e 'tell application "Pinwall" to quit' >/dev/null 2>&1 || pkill -x Pinwall || true
    sleep 1
fi

rm -rf "$APP"
ditto "$TMP/Pinwall.app" "$APP"
# Pinwall isn't notarized. Without this, macOS blocks the first launch and you'd have to
# allow it in System Settings, Privacy & Security.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")"
say "Installed Pinwall ${VERSION} in $INSTALL_DIR."

if ! mdfind "kMDItemCFBundleIdentifier == 'org.upscayl.Upscayl'" | grep -q .; then
    say ""
    say "Pinwall uses Upscayl (free) to upscale small pins. Get it at https://upscayl.org"
fi

[ -n "${PINWALL_NO_OPEN:-}" ] || open "$APP"
