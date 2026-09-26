#!/bin/bash
# Builds a universal Pinwall.zip and publishes it as a GitHub release for the version in
# version.env. Usage: Scripts/release.sh [notes-file]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source version.env
TAG="v$MARKETING_VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "$TAG already exists. Bump MARKETING_VERSION and BUILD_NUMBER in version.env first." >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first; the release is built from HEAD." >&2
    exit 1
fi

swift test
SIGNING_MODE=adhoc ARCHES="arm64 x86_64" Scripts/package_app.sh release

mkdir -p build
rm -f build/Pinwall.zip
# The install script downloads releases/latest/download/Pinwall.zip, so the name never changes.
ditto -c -k --keepParent Pinwall.app build/Pinwall.zip

NOTES=(--generate-notes)
if [ $# -ge 1 ]; then NOTES=(--notes-file "$1"); fi

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" build/Pinwall.zip --title "Pinwall $MARKETING_VERSION" "${NOTES[@]}"
