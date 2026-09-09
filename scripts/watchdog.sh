#!/bin/bash
# omlx-watchdog v6 — oMLX health check + auto-recovery (launchd, StartInterval=60s)
#
# v5 -> v6: model follows omlx dynamically via /api/status loaded_models[0]
#   (multi-model switching safe; nothing loaded -> model checks skipped, never force-loads).
# v5: default_model tracking. Fixes restart-loop incident where the watchdog kept
#   checking a stale model name after the user switched defaults.
# v4: PORT-CLEAN kills LISTENER only (lsof -sTCP:LISTEN), never client connections.
# v3/v4: Check A /api/status reachability; B model registered; C idle completion
#   probe (queue guaranteed empty); D token-counter stall >= 900s = wedged.
#
# Design: no self-interference — every check is either instant (A/B) or only runs
#   when the request queue is provably empty (C). The stall detector (D) only arms
#   while requests are in flight, so a healthy idle server is never flagged.
set -u

OMLX_BIN="${OMLX_WATCHDOG_OMLX_BIN:-/opt/homebrew/bin/omlx}"
OMLX_HOME="${OMLX_WATCHDOG_OMLX_HOME:-$HOME/.omlx}"
LOG_DIR="$OMLX_HOME/logs"
LOG_FILE="$LOG_DIR/watchdog.log"
STATS_STATE="/tmp/omlx-watchdog-state-v3"   # "LAST_TOK FROZEN_SINCE"(0=none)
FAIL_STATE="/tmp/omlx-watchdog-fails"       # compat (reset after restart)
API_BASE="${OMLX_WATCHDOG_API:-http://127.0.0.1:8000}"
STALL_SECONDS="${OMLX_WATCHDOG_STALL:-900}"

mkdir -p "$LOG_DIR"
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt 10485760 ]; then
  mv "$LOG_FILE" "$LOG_FILE.1"
fi

# re-entrancy guard (Check C probe up to 90s, may span ticks)
LOCK="/tmp/omlx-watchdog.lock"
if [ -f "$LOCK" ]; then
  oldpid=$(cat "$LOCK" 2>/dev/null)
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$LOCK"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }

KEY=$(python3 -c "import json;print(json.load(open('$OMLX_HOME/settings.json'))['auth']['api_key'])" 2>/dev/null)

status_json() {
  curl -sf --max-time 5 "$API_BASE/api/status" -H "Authorization: Bearer $KEY"
}

# v6: model = first actually-loaded model; empty when nothing is loaded (checks skipped).
# Empty = cannot verify (caller skips model check instead of restart-looping).
current_model() {
  local s
  s=$(status_json) || return 0
  [ -z "$s" ] && return 0
  python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('loaded_models') or [None])[0] or '')" <<<"$s" 2>/dev/null
}

check_models() {   # $1 = model name; unknown/empty -> skip check (return 0)
  [ -z "${1:-}" ] && return 0
  curl -sf --max-time 15 "$API_BASE/v1/models" -H "Authorization: Bearer $KEY" | grep -q "\"$1\""
}

# v5: kill LISTENER on port 8000 only (never client connections - v4 bug).
kill_port_holders() {
  local i lp port
  port=$(echo "$API_BASE" | grep -oE '[0-9]+$')
  [ -z "$port" ] && port=8000
  lp=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
  [ -z "$lp" ] && return 0
  log "PORT-CLEAN: listener pid=$lp -> kill"
  kill "$lp" 2>/dev/null || true
  for _ in $(seq 1 30); do   # up to 30s grace for listener exit
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || return 0
    sleep 1
  done
  lp=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
  if [ -n "$lp" ]; then
    log "PORT-CLEAN: still listening after 30s, kill -9 pid=$lp"
    kill -9 "$lp" 2>/dev/null || true
    sleep 3
  fi
}

do_restart() {
  log "ACTION: $OMLX_BIN restart --timeout 240"
  if ! "$OMLX_BIN" restart --timeout 240 >> "$LOG_FILE" 2>&1; then
    log "FALLBACK: omlx restart rc!=0, clean port listener and retry"
    kill_port_holders
    if ! "$OMLX_BIN" restart --timeout 240 >> "$LOG_FILE" 2>&1; then
      log "FALLBACK: open -a oMLX"
      open -a oMLX >> "$LOG_FILE" 2>&1 || log "FALLBACK FAILED: open -a oMLX also failed"
    fi
  fi
  ok="no"; m=""
  for _ in $(seq 1 24); do   # up to 24 x 10s = 4 min for /api/status
    sleep 10
    s=$(status_json) || continue
    m=$(python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('loaded_models') or [None])[0] or '')" <<<"$s" 2>/dev/null)
    ok="yes"; break
  done
  if [ "$ok" = "yes" ]; then
    log "RECOVERED: oMLX up (loaded=${m:-none})"
    echo 0 > "$FAIL_STATE"
    : > "$STATS_STATE"   # counters reset after restart, clear stall state
  else
    log "STILL DOWN: /api/status unreachable after restart; next tick continues"
  fi
}

# ---------- Check A: /api/status (instant, no queueing) ----------
S=$(status_json) || S=""
if [ -z "$S" ]; then
  log "HEALTH FAIL [A]: /api/status unreachable -> restart now"
  do_restart
  rm -f "$LOCK"; exit 0
fi

TOK=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('total_completion_tokens',0)+d.get('total_prompt_tokens',0))" <<<"$S" 2>/dev/null || echo -1)
ACTIVE=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('active_requests',0)+d.get('waiting_requests',0))" <<<"$S" 2>/dev/null || echo -1)
if [ "$TOK" = "-1" ] || [ "$ACTIVE" = "-1" ]; then
  log "HEALTH FAIL [A]: /api/status parse failed -> restart now"
  do_restart
  rm -f "$LOCK"; exit 0
fi

MODEL=$(python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('loaded_models') or [None])[0] or '')" <<<"$S" 2>/dev/null)

# ---------- Check B: current model registered (v5: dynamic, skip if unknown) ----------
if ! check_models "$MODEL"; then
  log "HEALTH FAIL [B]: model '$MODEL' not registered -> restart now"
  do_restart
  rm -f "$LOCK"; exit 0
fi

# ---------- Check C: idle completion probe (queue guaranteed empty) ----------
if [ "$ACTIVE" -eq 0 ]; then
  if [ -z "$MODEL" ]; then
    log "HEALTHY: server up, no model loaded (skip probe) tok=$TOK"
    echo "$TOK 0" > "$STATS_STATE"
    echo 0 > "$FAIL_STATE"
    rm -f "$LOCK"; exit 0
  fi
  if curl -sf --max-time 90 "$API_BASE/v1/chat/completions" \
      -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" > /dev/null; then
    log "HEALTHY: idle probe ok (model=$MODEL tok=$TOK)"
    echo "$TOK 0" > "$STATS_STATE"
    echo 0 > "$FAIL_STATE"
    rm -f "$LOCK"; exit 0
  else
    log "HEALTH FAIL [C]: idle probe failed (model=$MODEL) -> engine broken, restart"
    do_restart
    rm -f "$LOCK"; exit 0
  fi
fi

# ---------- Check D: requests in flight + token counter stalled (wedged) ----------
read -r LAST_TOK FROZEN_SINCE < "$STATS_STATE" 2>/dev/null
LAST_TOK=${LAST_TOK:--1}
FROZEN_SINCE=${FROZEN_SINCE:-0}

NOW=$(date +%s)
if [ "$TOK" -gt "$LAST_TOK" ]; then
  FROZEN_SINCE=0          # progress
elif [ "$TOK" -lt "$LAST_TOK" ]; then
  FROZEN_SINCE=0          # counters reset (external restart), re-arm timer
elif [ "$FROZEN_SINCE" -eq 0 ]; then
  FROZEN_SINCE=$NOW       # start stall timer (idle->active switch re-arms here)
fi

if [ "$FROZEN_SINCE" -gt 0 ]; then STALL=$((NOW - FROZEN_SINCE)); else STALL=0; fi
if [ "$FROZEN_SINCE" -gt 0 ] && [ $STALL -ge $STALL_SECONDS ]; then
  log "HEALTH FAIL [D]: token counter stalled ${STALL}s (active+waiting=$ACTIVE) -> wedged, restart"
  do_restart
else
  log "BUSY: model=${MODEL:-none} tok=$TOK active+waiting=$ACTIVE stall=${STALL}s (threshold ${STALL_SECONDS}s)"
fi

echo "$TOK $FROZEN_SINCE" > "$STATS_STATE"
rm -f "$LOCK"; exit 0
