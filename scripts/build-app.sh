#!/bin/zsh
# Builds "build/Clone Ranger.app" and "dist/Clone Ranger <version>.zip".
# Version comes from VERSION. Only the 5 newest zips are kept in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION | tr -d '[:space:]')
NAME="Clone Ranger"
APP="${BUILD_DIR:-build}/$NAME.app"   # BUILD_DIR=… to leave a running build/ copy alone

scripts/vendor-sdks.sh
swift build -c release --product CloneRanger

# App icon, drawn by the app itself (same drawing as the top bar and the report).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
CR_MAKE_ICON="$ICONSET/icon_512x512@2x.png" .build/release/CloneRanger
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); [[ $s == 512 ]] || sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CloneRanger "$APP/Contents/MacOS/$NAME"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
# Camera RAW decoders (loaded at run time; their makers' licenses allow shipping them inside the app).
mkdir -p "$APP/Contents/Frameworks"
[[ -d Vendor/BlackmagicRAW/BlackmagicRawAPI.framework ]] && ditto Vendor/BlackmagicRAW/BlackmagicRawAPI.framework "$APP/Contents/Frameworks/BlackmagicRawAPI.framework"
[[ -f Vendor/RED/Redistributable/REDR3D.dylib ]] && cp Vendor/RED/Redistributable/REDR3D.dylib "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.patrickdunnagan.cloneranger</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force -s - "$APP"

mkdir -p dist
ZIP="dist/$NAME $VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# Keep only the 5 newest builds.
ls -t dist/*.zip | tail -n +6 | while read -r old; do rm -f "$old"; done
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
