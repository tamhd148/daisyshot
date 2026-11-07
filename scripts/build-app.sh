#!/bin/bash
# Builds build/Daisyshot.app from the SwiftPM package (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-$(cat VERSION)}
SIGN_ID=${SIGN_ID:--}
swift build -c "$CONFIG"
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
# UNIVERSAL=1: also build for Intel and lipo both slices together (SwiftPM's multi-arch build needs Xcode).
if [ "${UNIVERSAL:-0}" = 1 ]; then
  T=x86_64-apple-macosx15.0
  swift build -c "$CONFIG" --triple "$T"
  INTEL="$(swift build -c "$CONFIG" --triple "$T" --show-bin-path)"
  FAT=build/universal; rm -rf "$FAT"; mkdir -p "$FAT"
  for B in Daisyshot DaisyshotShareExtension DaisyshotQuickLookExtension; do lipo -create "$BINDIR/$B" "$INTEL/$B" -output "$FAT/$B"; done
  BINDIR=$FAT
fi
APP=build/Daisyshot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp "$BINDIR/Daisyshot" "$APP/Contents/MacOS/Daisyshot"

# Bundle icon = the default "Handles" artwork; the other icons, menu bar glyphs and logotype are loaded at runtime (DS.image).
mkdir -p build
iconutil -c icns Assets/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Assets/AppIcons Assets/MenuBar Assets/Logo "$APP/Contents/Resources/"

# Localizations: Localization/<lang>/*.strings (English text → translation) are merged into <lang>.lproj/Localizable.strings;
# InfoPlist.strings localizes Info.plist values; appex/<Name>.strings is that extension's InfoPlist.strings.
# en.lproj is empty: English is the source language.
mkdir -p "$APP/Contents/Resources/en.lproj"
LANGS=en
for D in Localization/*/; do
  L=$(basename "$D"); LP="$APP/Contents/Resources/$L.lproj"; mkdir -p "$LP"; LANGS="$LANGS $L"
  find "$D" -maxdepth 1 -name '*.strings' ! -name InfoPlist.strings -print0 | sort -z | xargs -0 cat > "$LP/Localizable.strings"
  plutil -lint -s "$LP/Localizable.strings"
  [ -f "$D/InfoPlist.strings" ] && cp "$D/InfoPlist.strings" "$LP/"
done
LOCALIZATIONS=$(for L in $LANGS; do printf '<string>%s</string>' "$L"; done)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.daisyshot.mac</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>$LOCALIZATIONS</array>
  <key>CFBundleName</key><string>Daisyshot</string>
  <key>CFBundleDisplayName</key><string>Daisyshot</string>
  <key>CFBundleExecutable</key><string>Daisyshot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Tam Hoang. MIT License.</string>
  <key>NSCameraUsageDescription</key><string>Daisyshot uses the camera only to show your webcam during recordings.</string>
  <key>NSMicrophoneUsageDescription</key><string>Daisyshot uses the microphone only to record your voice during recordings.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>app.daisyshot.mac</string>
    <key>CFBundleURLSchemes</key><array><string>daisyshot</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.png</string><string>public.jpeg</string><string>public.heic</string><string>public.tiff</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Daisyshot Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.daisyshot.document</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Daisyshot Video Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>app.daisyshot.videoproject</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>app.daisyshot.document</string>
    <key>UTTypeDescription</key><string>Daisyshot Document</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>daisyshot</string></array></dict>
  </dict>
  <dict>
    <key>UTTypeIdentifier</key><string>app.daisyshot.videoproject</string>
    <key>UTTypeDescription</key><string>Daisyshot Video Project</string>
    <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>daisyshotvideo</string></array></dict>
  </dict></array>
</dict>
</plist>
PLIST

# App extensions: make_appex <Name> <DisplayName> <executable target> <NSExtension dict body>
# Sandboxed, signed before the app (inside-out, no --deep).
make_appex() {
  local X="$APP/Contents/PlugIns/$1.appex"
  mkdir -p "$X/Contents/MacOS" "$X/Contents/Resources"
  cp "$BINDIR/$3" "$X/Contents/MacOS/$1"
  cp build/AppIcon.icns "$X/Contents/Resources/AppIcon.icns"
  for L in $LANGS; do
    [ "$L" = en ] && continue
    mkdir -p "$X/Contents/Resources/$L.lproj"
    cp "$APP/Contents/Resources/$L.lproj/Localizable.strings" "$X/Contents/Resources/$L.lproj/"
    [ -f "Localization/$L/appex/$1.strings" ] && cp "Localization/$L/appex/$1.strings" "$X/Contents/Resources/$L.lproj/InfoPlist.strings"
  done
  cat > "$X/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.daisyshot.mac.$1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>$LOCALIZATIONS</array>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleDisplayName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSExtension</key>
  <dict>
$4
  </dict>
</dict>
</plist>
PLIST
  codesign --force --options runtime --entitlements scripts/Extension.entitlements -s "$SIGN_ID" "$X"
}

SHARE_RULE='<key>NSExtensionAttributes</key><dict><key>NSExtensionActivationRule</key><dict>
      <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>1</integer>
    </dict></dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key><string>DaisyshotShareViewController</string>'
make_appex AnnotateShareExtension "Annotate with Daisyshot" DaisyshotShareExtension "$SHARE_RULE"
make_appex PinShareExtension "Pin with Daisyshot" DaisyshotShareExtension "$SHARE_RULE"
make_appex QuickLookExtension "Daisyshot Quick Look" DaisyshotQuickLookExtension \
  '<key>NSExtensionAttributes</key><dict>
      <key>QLSupportedContentTypes</key><array><string>app.daisyshot.document</string><string>app.daisyshot.videoproject</string></array>
      <key>QLSupportsSearchableItems</key><false/>
      <key>QLIsDataBasedPreview</key><true/>
    </dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.preview</string>
    <key>NSExtensionPrincipalClass</key><string>DaisyshotPreviewProvider</string>'
make_appex QuickLookThumbnailingExtension "Daisyshot Thumbnails" DaisyshotQuickLookExtension \
  '<key>NSExtensionAttributes</key><dict>
      <key>QLSupportedContentTypes</key><array><string>app.daisyshot.document</string><string>app.daisyshot.videoproject</string></array>
      <key>QLThumbnailMinimumDimension</key><integer>0</integer>
    </dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key><string>DaisyshotThumbnailProvider</string>'

# Ad-hoc signatures are normally identified by their hash, so macOS asks for Screen Recording / Accessibility again
# after every rebuild. Pinning the designated requirement to the bundle ID keeps those grants across rebuilds.
# (A real SIGN_ID gets the usual certificate-based requirement instead.)
REQ=()
[ "$SIGN_ID" = "-" ] && REQ=(--requirements '=designated => identifier "app.daisyshot.mac"')
codesign --force --options runtime --entitlements scripts/Daisyshot.entitlements ${REQ[@]+"${REQ[@]}"} -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION)"
echo "Install: ditto $APP /Applications/Daisyshot.app && open /Applications/Daisyshot.app"
echo "         (launching it registers the Share and Quick Look extensions; enable Share items in"
echo "          System Settings › General › Login Items & Extensions › Sharing)"
