#!/bin/bash
# Builds a universal (Apple silicon + Intel) Daisyshot.app and wraps it in build/Daisyshot-<version>.dmg with an
# Applications shortcut and install notes. The app is ad-hoc signed, not notarized: see the notes for first launch.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-$(cat VERSION)}
UNIVERSAL=1 ./scripts/build-app.sh
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto build/Daisyshot.app "$STAGE/Daisyshot.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-readme.txt "$STAGE/Đọc trước khi cài - Read me.txt"
DMG="build/Daisyshot-$VERSION.dmg"
hdiutil create -volname "Daisyshot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
