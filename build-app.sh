#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"

swift build -c release
mkdir -p TrailPoint.app/Contents/MacOS TrailPoint.app/Contents/Resources
cp .build/release/TrailPoint TrailPoint.app/Contents/MacOS/TrailPoint
cp AppInfo.plist TrailPoint.app/Contents/Info.plist
cp AppIcon.icns TrailPoint.app/Contents/Resources/AppIcon.icns

if [[ -f "VERSION" ]]; then
  VERSION="$(cat VERSION)"
  plutil -replace CFBundleShortVersionString -string "$VERSION" TrailPoint.app/Contents/Info.plist
  plutil -replace CFBundleVersion -string "$VERSION" TrailPoint.app/Contents/Info.plist
  echo "Set app version to $VERSION"
fi

identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application.*Spaulding/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
fi

if [[ -z "$identity" && -n "${REQUIRE_DEVELOPER_ID:-}" ]]; then
  echo "error: Developer ID Application identity is required for a signed release" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

if [[ -n "$identity" ]]; then
  # A Developer ID requirement stays stable across source rebuilds, which lets
  # macOS retain TrailPoint's Accessibility grant between app updates.
  codesign --force --options runtime --timestamp --entitlements TrailPoint.entitlements --sign "$identity" TrailPoint.app
  echo "Signed with $identity"
else
  # Keep local builds usable on a Mac without a signing certificate.
  codesign --force --entitlements TrailPoint.entitlements --sign - TrailPoint.app
  echo "Ad-hoc signed (no Developer ID identity found)"
fi

echo "Built TrailPoint.app"
