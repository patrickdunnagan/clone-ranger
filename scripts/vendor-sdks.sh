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
