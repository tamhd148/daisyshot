#!/bin/bash
# Publishes a release: bump VERSION first, write the notes (Markdown), then
#   ./scripts/release.sh notes.md
# Builds the universal app and disk image, makes the update archive Daisyshot-<version>.zip, signs it
# (scripts/update-key.swift, key outside the repository) and creates the GitHub release with all three files.
# Installed copies find it with Check for Updates… (or their daily check) and install it after checking the signature.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=${1:?Usage: ./scripts/release.sh NOTES.md}
VERSION=$(cat VERSION)
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then echo "Release $TAG already exists — bump VERSION first." >&2; exit 1; fi
if [ -n "$(git status --porcelain)" ]; then echo "Commit your changes first (the release is tagged at HEAD)." >&2; exit 1; fi

./scripts/make-dmg.sh
ZIP="build/Daisyshot-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/Daisyshot.app "$ZIP"
swift scripts/update-key.swift sign "$ZIP" > "$ZIP.sig"

gh release create "$TAG" "build/Daisyshot-$VERSION.dmg" "$ZIP" "$ZIP.sig" \
  --title "Daisyshot $VERSION" --notes-file "$NOTES" --target "$(git rev-parse HEAD)"
echo "Released $TAG"
