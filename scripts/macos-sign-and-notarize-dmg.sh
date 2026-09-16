#!/usr/bin/env bash
# Deep-sign TrailPoint.app (Developer ID Application), productsign TrailPointAgent.pkg
# (Developer ID Installer), build a UDZO DMG, submit to notarytool, staple.
#
# Usage:
#   DEVELOPER_ID_APPLICATION_P12_BASE64=... \
#   DEVELOPER_ID_INSTALLER_P12_BASE64=... \
#   DEVELOPER_ID_P12_PASSWORD=... \
#   APP_STORE_CONNECT_API_KEY_P8=... \
#   APP_STORE_CONNECT_KEY_ID=... \
#   APP_STORE_CONNECT_ISSUER_ID=... \
#   ./scripts/macos-sign-and-notarize-dmg.sh \
#     --app dmg-staging/TrailPoint.app \
#     --pkg dmg-staging/TrailPointAgent.pkg \
#     --dmg TrailPoint-1.0.0-macOS-arm64.dmg \
#     --staging dmg-staging
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT/TrailPoint.entitlements"

APP=""
PKG=""
DMG=""
STAGING=""
VERSION="${TRAILPOINT_VERSION:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?}"; shift 2 ;;
    --pkg) PKG="${2:?}"; shift 2 ;;
    --dmg) DMG="${2:?}"; shift 2 ;;
    --staging) STAGING="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$APP" && -d "$APP" ]] || { echo "error: --app must be a TrailPoint.app bundle" >&2; exit 2; }
[[ -f "$ENTITLEMENTS" ]] || { echo "error: entitlements missing: $ENTITLEMENTS" >&2; exit 2; }

if [[ -z "$VERSION" ]]; then
  VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
fi
if [[ -z "$DMG" ]]; then
  DMG="$ROOT/TrailPoint-${VERSION}.dmg"
fi
if [[ -z "$STAGING" ]]; then
  STAGING="$(dirname "$APP")"
fi

: "${DEVELOPER_ID_APPLICATION_P12_BASE64:?Set DEVELOPER_ID_APPLICATION_P12_BASE64}"
: "${DEVELOPER_ID_INSTALLER_P12_BASE64:?Set DEVELOPER_ID_INSTALLER_P12_BASE64}"
: "${DEVELOPER_ID_P12_PASSWORD:?Set DEVELOPER_ID_P12_PASSWORD}"

APP_STORE_CONNECT_API_KEY="$(printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" | base64 | tr -d '\n')"
: "${APP_STORE_CONNECT_API_KEY:?Set APP_STORE_CONNECT_API_KEY_P8}"
: "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/trailpoint-devid-XXXXXX")"
KEYCHAIN="$WORKDIR/trailpoint-devid.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
APP_P12="$WORKDIR/developer_id_application.p12"
INST_P12="$WORKDIR/developer_id_installer.p12"
ASC_P8="$WORKDIR/AuthKey.p8"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

printf '%s' "$DEVELOPER_ID_APPLICATION_P12_BASE64" | base64 -d >"$APP_P12"
printf '%s' "$DEVELOPER_ID_INSTALLER_P12_BASE64" | base64 -d >"$INST_P12"
[[ -s "$APP_P12" && -s "$INST_P12" ]] || { echo "error: P12 decode produced empty file" >&2; exit 1; }

echo "Creating temporary signing keychain..."
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
EXISTING_KC="$(security list-keychains -d user | sed 's/"//g' | tr '\n' ' ')"
security list-keychains -d user -s "$KEYCHAIN" $EXISTING_KC

security import "$APP_P12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign >/dev/null
security import "$INST_P12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign >/dev/null

DEVID_G2="$WORKDIR/DeveloperIDG2CA.cer"
if curl -fsSL -o "$DEVID_G2" \
  https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer; then
  security import "$DEVID_G2" -k "$KEYCHAIN" -T /usr/bin/codesign \
    -T /usr/bin/security -T /usr/bin/productsign >/dev/null 2>&1 \
    || security add-certificates -k "$KEYCHAIN" "$DEVID_G2" >/dev/null 2>&1 \
    || true
fi
security set-key-partition-list -S apple-tool:,apple:,codesign:,productsign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

APP_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
INST_IDENTITY="$(security find-identity -v "$KEYCHAIN" \
  | awk -F'"' '/Developer ID Installer/ { print $2; exit }')"
[[ -n "$APP_IDENTITY" ]] || { echo "error: no Developer ID Application identity in keychain" >&2; exit 1; }
[[ -n "$INST_IDENTITY" ]] || { echo "error: no Developer ID Installer identity in keychain" >&2; exit 1; }

chmod -R u+w "$APP"
find "$APP/Contents/MacOS" -type f -exec chmod +x {} + 2>/dev/null || true
find "$APP" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$APP_IDENTITY" "$APP/Contents/MacOS/TrailPoint"

/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$APP_IDENTITY" "$APP"

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -n "$PKG" ]]; then
  echo "Building agent pkg from sealed app → $PKG"
  chmod +x "$ROOT/scripts/macos-launch-agent-pkg.sh"
  TRAILPOINT_VERSION="$VERSION" TRAILPOINT_APP_SRC="$APP" \
    "$ROOT/scripts/macos-launch-agent-pkg.sh" "$PKG"
  echo "productsign $PKG ..."
  SIGNED_PKG="$WORKDIR/TrailPointAgent-signed.pkg"
  productsign --sign "$INST_IDENTITY" --timestamp "$PKG" "$SIGNED_PKG"
  mv -f "$SIGNED_PKG" "$PKG"
  pkgutil --check-signature "$PKG" || true
fi

if [[ -d "$STAGING" ]]; then
  [[ -e "$STAGING/Applications" ]] || ln -s /Applications "$STAGING/Applications"
  if [[ ! -f "$STAGING/README.txt" ]]; then
    {
      echo 'TrailPoint macOS install'
      echo '========================'
      echo 'Option A (app only): drag TrailPoint.app into Applications.'
      echo 'Option B (recommended): double-click TrailPointAgent.pkg to install'
      echo '  TrailPoint.app and set it up to launch automatically on login.'
    } >"$STAGING/README.txt"
  fi
  [[ -d "$STAGING/TrailPoint.app" ]] || { echo "error: $STAGING/TrailPoint.app missing" >&2; exit 1; }
  echo "Building DMG from $STAGING → $DMG"
  rm -f "$DMG"
  hdiutil create -volname "TrailPoint" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG"
else
  [[ -f "$DMG" ]] || { echo "error: DMG missing and no --staging to build from" >&2; exit 1; }
fi

printf '%s' "$APP_STORE_CONNECT_API_KEY" | base64 -d >"$ASC_P8"
[[ -s "$ASC_P8" ]] || { echo "error: APP_STORE_CONNECT_API_KEY did not decode to a .p8" >&2; exit 1; }

echo "Submitting $DMG to notarytool (wait)..."
xcrun notarytool submit "$DMG" \
  --key "$ASC_P8" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

echo "Stapling ticket..."
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP" 2>/dev/null || true
if [[ -n "$PKG" && -f "$PKG" ]]; then
  xcrun stapler staple "$PKG" 2>/dev/null || true
fi

echo "Final Gatekeeper assessment..."
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 || true
codesign --verify --deep --strict --verbose=2 "$APP"
echo "OK: notarized DMG at $DMG"
