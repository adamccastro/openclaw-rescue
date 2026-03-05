#!/usr/bin/env bash
# OpenClaw Gateway Rescue Watchdog

RESCUE_ENV="${HOME}/.openclaw/rescue.env"
LOG_FILE="${HOME}/.openclaw/logs/rescue.log"
CHECK_INTERVAL=30
FAILURE_THRESHOLD=3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESCUE_BOT="${SCRIPT_DIR}/rescue-bot.js"
RESCUE_BOT_PID=""

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/adamcastro}"

mkdir -p "${HOME}/.openclaw/logs"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
}

# Source credentials
if [[ -f "$RESCUE_ENV" ]]; then
  source "$RESCUE_ENV"
else
  log "ERROR: ${RESCUE_ENV} not found."
  exit 1
fi

send_telegram() {
  local message="$1"
  curl -sf -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\": \"${ADMIN_CHAT_ID}\", \"text\": $(python3 -c "import sys,json; print(json.dumps('''$message'''))" 2>/dev/null || echo "\"$message\"")}" \
    >/dev/null 2>&1 || true
}

check_gateway() {
  openclaw gateway status >/dev/null 2>&1
  return $?
}

spawn_rescue_bot() {
  if [[ -n "$RESCUE_BOT_PID" ]] && kill -0 "$RESCUE_BOT_PID" 2>/dev/null; then
    return
  fi
  TELEGRAM_BOT_TOKEN="$BOT_TOKEN" ADMIN_CHAT_ID="$ADMIN_CHAT_ID" \
    node "$RESCUE_BOT" >> "$LOG_FILE" 2>&1 &
  RESCUE_BOT_PID=$!
  log "Rescue bot started (PID ${RESCUE_BOT_PID})"
}

consecutive_failures=0

log "OpenClaw Rescue Watchdog started (interval=${CHECK_INTERVAL}s, threshold=${FAILURE_THRESHOLD})"

while true; do
  if check_gateway; then
    if [[ $consecutive_failures -gt 0 ]]; then
      log "Gateway recovered after ${consecutive_failures} failures"
      consecutive_failures=0
    fi
  else
    consecutive_failures=$((consecutive_failures + 1))
    log "Gateway check failed (${consecutive_failures}/${FAILURE_THRESHOLD})"

    if [[ $consecutive_failures -ge $FAILURE_THRESHOLD ]]; then
      log "Threshold reached — running doctor --repair..."
      doctor_output=$(openclaw doctor --repair --yes 2>&1) || true
      log "Doctor: ${doctor_output}"

      sleep 5

      if check_gateway; then
        log "Gateway recovered via auto-repair"
        send_telegram "✅ [OpenClaw] Gateway recovered via auto-repair after ${consecutive_failures} failures."
        consecutive_failures=0
      else
        log "Auto-repair failed — gateway still down. Alerting + spawning rescue bot."
        send_telegram "🚨 [OpenClaw] Gateway is DOWN. Auto-repair failed. Rescue bot activated — send /help"
        spawn_rescue_bot
      fi
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
