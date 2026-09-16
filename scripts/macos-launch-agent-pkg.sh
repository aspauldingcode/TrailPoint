#!/usr/bin/env bash
# Build TrailPointAgent.pkg for the macOS DMG.
#
# Hybrid installer: the pkg PAYLOAD installs /Applications/TrailPoint.app AND the
# postinstall writes + loads the LaunchAgent into the user launchd domain so TrailPoint
# starts automatically on login.
#
# Usage:
#   TRAILPOINT_APP_SRC=/path/to/TrailPoint.app TRAILPOINT_VERSION=1.0.0 \
#     scripts/macos-launch-agent-pkg.sh /out/TrailPointAgent.pkg
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/TrailPointAgent.pkg}"
IDENTIFIER="${TRAILPOINT_PKG_ID:-com.aspauldingcode.trailpoint.agent}"
VERSION="${TRAILPOINT_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)}"
APP_SRC="${TRAILPOINT_APP_SRC:-}"

if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "error: TRAILPOINT_APP_SRC must point at a built TrailPoint.app (got: '${APP_SRC:-<unset>}')" >&2
  exit 2
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/trailpoint-agent-pkg.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

PAYLOAD="$WORKDIR/payload"
SCRIPTS="$WORKDIR/scripts"
mkdir -p "$PAYLOAD/Applications" "$SCRIPTS"

ditto "$APP_SRC" "$PAYLOAD/Applications/TrailPoint.app"
chmod -R u+w "$PAYLOAD/Applications/TrailPoint.app"
find "$PAYLOAD/Applications/TrailPoint.app/Contents/MacOS" -type f -exec chmod +x {} + 2>/dev/null || true
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true
find "$PAYLOAD" -name '.DS_Store' -delete 2>/dev/null || true

cat >"$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
set -euo pipefail

APP_EXEC="/Applications/TrailPoint.app/Contents/MacOS/TrailPoint"
LAUNCHAGENT_LABEL="com.aspauldingcode.trailpoint"

if [[ ! -x "$APP_EXEC" ]]; then
  echo "error: $APP_EXEC not found after payload install." >&2
  exit 1
fi

RUNNING_UID="$(id -u)"

resolve_target_users() {
  local console_uid
  console_uid="$(stat -f %u /dev/console 2>/dev/null || echo "")"
  if [[ -z "$console_uid" || "$console_uid" == "0" ]]; then
    console_uid="$RUNNING_UID"
  fi
  id -un "$console_uid"
}

write_agent() {
  local label="$1" owner="$2"
  local uid
  uid="$(id -u "$owner")"
  local plist_path="$3/$label.plist"
  cat >"$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_EXEC</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
PLIST
  chown "$owner" "$plist_path" 2>/dev/null || true
}

install_for_user() {
  local user="$1"
  local uid home la_dir domain
  uid="$(id -u "$user" 2>/dev/null || echo "")"
  if [[ -z "$uid" ]]; then
    echo "error: user '$user' does not exist" >&2
    return 1
  fi
  home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [[ -z "${home:-}" ]]; then
    home="$(eval echo "~$user")"
  fi
  la_dir="$home/Library/LaunchAgents"
  domain="gui/$uid"

  mkdir -p "$la_dir"
  chown "$user" "$la_dir" 2>/dev/null || true

  as_user() {
    if [[ "$RUNNING_UID" -eq 0 ]]; then
      launchctl asuser "$uid" "$@"
    else
      "$@"
    fi
  }

  ensure_loaded() {
    local label="$1"
    local target="$domain/$label"
    as_user launchctl bootout "$target" >/dev/null 2>&1 || true
    as_user launchctl bootstrap "$domain" "$la_dir/$label.plist"
    as_user launchctl kickstart -k "$target" >/dev/null 2>&1 || true
  }

  write_agent "$LAUNCHAGENT_LABEL" "$user" "$la_dir"
  ensure_loaded "$LAUNCHAGENT_LABEL"

  echo "TrailPoint LaunchAgent installed for $user: $LAUNCHAGENT_LABEL"
}

rc=0
for user in $(resolve_target_users); do
  install_for_user "$user" || rc=1
done
exit $rc
EOF
chmod 755 "$SCRIPTS/postinstall"
rm -f "$SCRIPTS"/._* "$SCRIPTS"/.DS_Store

COPYFILE_DISABLE=1 pkgbuild \
  --root "$PAYLOAD" \
  --scripts "$SCRIPTS" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$OUT"

echo "Built $OUT"
ls -lah "$OUT"
