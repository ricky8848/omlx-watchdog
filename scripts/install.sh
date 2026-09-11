#!/bin/bash
# omlx-watchdog — one-click installer (macOS, Apple Silicon)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
#   # or with options:
#   OMLX_WATCHDOG_API=http://127.0.0.1:8000 OMLX_WATCHDOG_STALL=900 bash install.sh
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main"
OMLX_HOME="${OMLX_WATCHDOG_OMLX_HOME:-$HOME/.omlx}"
API_BASE="${OMLX_WATCHDOG_API:-http://127.0.0.1:8000}"
STALL_SECONDS="${OMLX_WATCHDOG_STALL:-900}"
RESTART_COOLDOWN="${OMLX_WATCHDOG_RESTART_COOLDOWN:-300}"
DOCKER_CLI="${OMLX_WATCHDOG_DOCKER:-/usr/local/bin/docker}"

echo "==> omlx-watchdog installer (v9.1)"
echo "    OMLX_HOME:  $OMLX_HOME"
echo "    API_BASE:   $API_BASE"
echo "    STALL_SECONDS: $STALL_SECONDS"
echo "    RESTART_COOLDOWN: ${RESTART_COOLDOWN}s (v9)"
echo "    DOCKER_CLI: $DOCKER_CLI"

# ---- preflight checks -------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this installer targets macOS (Apple Silicon)." >&2; exit 1
fi

if [ ! -d "$OMLX_HOME" ]; then
  echo "ERROR: $OMLX_HOME not found — install oMLX first (https://omlx.ai)." >&2; exit 1
fi

if [ ! -f "$OMLX_HOME/settings.json" ]; then
  echo "ERROR: $OMLX_HOME/settings.json not found — start oMLX at least once." >&2; exit 1
fi

# find the omlx CLI (Homebrew or app bundle)
OMLX_BIN=""
for cand in /opt/homebrew/bin/omlx /usr/local/bin/omlx; do
  [ -x "$cand" ] && OMLX_BIN="$cand" && break
done
if [ -z "$OMLX_BIN" ]; then
  echo "WARN: omlx CLI not found in PATH (looked for /opt/homebrew/bin/omlx, /usr/local/bin/omlx)."
  echo "      The watchdog will fall back to 'open -a oMLX' for recovery."
fi

# verify API is reachable (warn only — the watchdog will start anyway)
if ! curl -sf --max-time 3 "$API_BASE/api/status" >/dev/null 2>&1; then
  echo "WARN: $API_BASE/api/status not reachable right now (no API key sent)."
  echo "      This is normal if oMLX is not running yet; the watchdog will start it."
fi

# v8: check Docker Desktop (warn only — merged into watchdog)
if ! pgrep -f "Docker Desktop" >/dev/null 2>&1 && ! "$DOCKER_CLI" info >/dev/null 2>&1; then
  echo "WARN: Docker Desktop not running and daemon unreachable."
  echo "      The watchdog will launch it automatically on the next tick if needed."
fi

# v9: check for existing cooldown state (info only)
if [ -f "/tmp/omlx-watchdog-cooldown" ]; then
  _last_restart=$(cat /tmp/omlx-watchdog-cooldown 2>/dev/null)
  _now=$(date +%s)
  if [ -n "$_last_restart" ] && [ $((_now - _last_restart)) -lt 300 ]; then
    echo "INFO: recent restart detected ($((_now - _last_restart))s ago) — cooldown active for $((300 - (_now - _last_restart)))s"
  fi
fi

# ---- install files -----------------------------------------------------
mkdir -p "$OMLX_HOME/logs"

echo "==> downloading watchdog.sh -> $OMLX_HOME/watchdog.sh"
curl -fsSL "$REPO_URL/scripts/watchdog.sh" -o "$OMLX_HOME/watchdog.sh.new"
chmod +x "$OMLX_HOME/watchdog.sh.new"

# keep a backup of any previous version
if [ -f "$OMLX_HOME/watchdog.sh" ]; then
  cp "$OMLX_HOME/watchdog.sh" "$OMLX_HOME/watchdog.sh.bak.$(date +%Y%m%d%H%M%S)"
fi
mv "$OMLX_HOME/watchdog.sh.new" "$OMLX_HOME/watchdog.sh"

# ---- install launchd agent ---------------------------------------------
LABEL="com.ricky8848.omlx-watchdog"
PLIST_SRC="$OMLX_HOME/omlx-watchdog.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

# stop existing agent (ignore errors)
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "==> writing launchd plist -> $PLIST_DST"
cat > "$PLIST_SRC" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$OMLX_HOME/watchdog.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OMLX_WATCHDOG_API</key><string>$API_BASE</string>
    <key>OMLX_WATCHDOG_STALL</key><string>$STALL_SECONDS</string>
    <key>OMLX_WATCHDOG_RESTART_COOLDOWN</key><string>$RESTART_COOLDOWN</string>
    <key>OMLX_WATCHDOG_DOCKER</key><string>$DOCKER_CLI</string>
  </dict>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$OMLX_HOME/logs/watchdog-stdout.log</string>
  <key>StandardErrorPath</key><string>$OMLX_HOME/logs/watchdog-stderr.log</string>
</dict>
</plist>
EOF

mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"

echo "==> loading launchd agent $LABEL"
launchctl load -w "$PLIST_DST"

# ---- verify -------------------------------------------------------------
sleep 2
if launchctl list | grep -q "$LABEL"; then
  echo ""
  echo "✅ omlx-watchdog installed and running."
  echo ""
  echo "   Script:      $OMLX_HOME/watchdog.sh"
  echo "   Plist:       $PLIST_DST"
  echo "   Log:         $OMLX_HOME/logs/watchdog.log"
  echo ""
  echo "   Uninstall:   launchctl unload $PLIST_DST && rm -f '$PLIST_DST' '$OMLX_HOME/watchdog.sh'"
  echo "   Check now:   tail -f $OMLX_HOME/logs/watchdog.log"
else
  echo ""
  echo "⚠️  installed but launchd did not register the agent. Try:"
  echo "    launchctl load -w $PLIST_DST"
fi
