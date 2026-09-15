#!/bin/zsh
set -euo pipefail

swift build -c release
mkdir -p TrailPoint.app/Contents/MacOS
cp .build/release/TrailPoint TrailPoint.app/Contents/MacOS/TrailPoint
cp AppInfo.plist TrailPoint.app/Contents/Info.plist
trailpoint_signing_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
if [[ -n "$trailpoint_signing_identity" ]]; then
  # A Developer ID requirement stays stable across source rebuilds, which lets
  # macOS retain TrailPoint's Accessibility grant between app updates.
  codesign --force --options runtime --entitlements TrailPoint.entitlements --sign "$trailpoint_signing_identity" TrailPoint.app
else
  # Keep local builds usable on a Mac without a signing certificate.
  codesign --force --entitlements TrailPoint.entitlements --sign - TrailPoint.app
fi
echo "Built TrailPoint.app"
