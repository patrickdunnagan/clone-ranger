#!/bin/zsh
# Copies the camera RAW SDK parts the build needs into Vendor/ (git-ignored: the SDKs' licenses allow
# shipping their runtime libraries inside the app, not publishing the SDKs themselves).
set -euo pipefail
cd "$(dirname "$0")/.."
BRAW="/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac"
if [[ -d "$BRAW" ]]; then
  mkdir -p Vendor/BlackmagicRAW/Include
  cp "$BRAW/Include/BlackmagicRawAPI.h" "$BRAW/Include/BlackmagicRawAPIDispatch.cpp" Vendor/BlackmagicRAW/Include/
  rm -rf Vendor/BlackmagicRAW/BlackmagicRawAPI.framework
  ditto "$BRAW/Libraries/BlackmagicRawAPI.framework" Vendor/BlackmagicRAW/BlackmagicRawAPI.framework
  echo "Blackmagic RAW SDK: $(defaults read "$PWD/Vendor/BlackmagicRAW/BlackmagicRawAPI.framework/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo copied)"
else
  echo "Blackmagic RAW SDK not installed (expected $BRAW); BRAW frames will be skipped" >&2
fi

# RED R3D SDK: the newest R3DSDKv* folder in Downloads (or R3D_SDK=<folder>).
R3D="${R3D_SDK:-$(ls -d "$HOME"/Downloads/R3DSDKv* 2>/dev/null | grep -v '\.zip$' | sort -V | tail -1)}"
if [[ -n "$R3D" && -d "$R3D/Include" ]]; then
  mkdir -p Vendor/RED/Include Vendor/RED/Lib Vendor/RED/Redistributable
  cp "$R3D"/Include/*.h Vendor/RED/Include/
  cp "$R3D/Lib/mac64/libR3DSDK-libcpp.a" Vendor/RED/Lib/
  cp "$R3D/Redistributable/mac/REDR3D.dylib" Vendor/RED/Redistributable/
  echo "RED R3D SDK: $(basename "$R3D")"
else
  echo "RED R3D SDK not found in Downloads; R3D frames will be skipped" >&2
fi
