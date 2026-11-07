#!/bin/bash
# Smoke-tests build/Daisyshot.app's extensions: registers them, then renders Quick Look thumbnails/previews for
# an image-only .daisyshot (version 1 files) and a current one (`previewPNG` + `thumbnailPNG`). Run after scripts/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Daisyshot.app
OUT=$(mktemp -d)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
for X in "$APP"/Contents/PlugIns/*.appex; do
  pluginkit -a "$X"
  ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$X/Contents/Info.plist")
  pluginkit -m -i "$ID" | grep -q "$ID" || { echo "FAIL: $ID not registered"; exit 1; }
done

b64() { base64 -i "$1" | tr -d '\n'; }
IMG=Assets/AppIcon.iconset/icon_256x256@2x.png   # 512 px
THUMB=Assets/AppIcon.iconset/icon_32x32.png      # 32 px: proves thumbnailPNG wins over image
printf '{"version":1,"scale":2,"annotations":[],"image":"%s"}' "$(b64 "$IMG")" > "$OUT/legacy.daisyshot"
printf '{"version":1,"scale":2,"annotations":[],"image":"%s","previewPNG":"%s","thumbnailPNG":"%s"}' \
  "$(b64 "$IMG")" "$(b64 "$IMG")" "$(b64 "$THUMB")" > "$OUT/new.daisyshot"

for F in legacy.daisyshot new.daisyshot; do
  T="$OUT/$F.png"
  for _ in 1 2 3; do  # right after (re)registration quicklookd may not see the extension yet
    qlmanage -x -t -s 256 -o "$OUT" "$OUT/$F" >/dev/null 2>&1 || true  # -x: via quicklookd, which runs appex providers
    [ -f "$T" ] && break || sleep 2
  done
  [ -f "$T" ] || { echo "FAIL: no thumbnail for $F"; exit 1; }
  W=$(sips -g pixelWidth "$T" | awk '/pixelWidth/ {print $2}')
  echo "$F thumbnail: $W px"
done
[ "$W" = 32 ] || { echo "FAIL: new.daisyshot thumbnail should come from thumbnailPNG (32 px)"; exit 1; }
echo "OK (files in $OUT; preview with: qlmanage -p $OUT/new.daisyshot)"
