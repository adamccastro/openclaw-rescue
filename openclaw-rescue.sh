#!/usr/bin/env bash
# OpenClaw Gateway Rescue Watchdog
# Monitors gateway health, auto-repairs, and spawns rescue bot if needed

set -euo pipefail

# --- Configuration ---
RESCUE_ENV="${HOME}/.openclaw/rescue.env"
LOG_DIR="/tmp/openclaw"
LOG_FILE="${LOG_DIR}/rescue.log"
CHECK_INTERVAL=30
FAILURE_THRESHOLD=3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESCUE_BOT="${SCRIPT_DIR}/rescue-bot.js"
RESCUE_BOT_PID=""

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

# --- Setup ---
mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Source rescue.env for BOT_TOKEN and ADMIN_CHAT_ID
if [[ -f "$RESCUE_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$RESCUE_ENV"
else
  log "ERROR: ${RESCUE_ENV} not found. Run install.sh first."
  exit 1
fi

if [[ -z "${BOT_TOKEN:-}" || -z "${ADMIN_CHAT_ID:-}" ]]; then
  log "ERROR: BOT_TOKEN and ADMIN_CHAT_ID must be set in ${RESCUE_ENV}"
  exit 1
fi

# --- Telegram notification helper ---
send_telegram() {
  local message="$1"
  curl -sf -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\": \"${ADMIN_CHAT_ID}\", \"text\": $(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
    > /dev/null 2>&1 || log "WARNING: Failed to send Telegram notification"
}

# --- Rescue bot management ---
is_rescue_bot_running() {
  if [[ -n "$RESCUE_BOT_PID" ]] && kill -0 "$RESCUE_BOT_PID" 2>/dev/null; then
    return 0
  fi
  RESCUE_BOT_PID=""
  return 1
}

spawn_rescue_bot() {
  if is_rescue_bot_running; then
    log "Rescue bot already running (PID ${RESCUE_BOT_PID})"
    return
  fi
  log "Spawning rescue bot..."
  TELEGRAM_BOT_TOKEN="$BOT_TOKEN" ADMIN_CHAT_ID="$ADMIN_CHAT_ID" \
    node "$RESCUE_BOT" >> "$LOG_FILE" 2>&1 &
  RESCUE_BOT_PID=$!
  log "Rescue bot started (PID ${RESCUE_BOT_PID})"
}

stop_rescue_bot() {
  if is_rescue_bot_running; then
    log "Stopping rescue bot (PID ${RESCUE_BOT_PID})..."
    kill "$RESCUE_BOT_PID" 2>/dev/null || true
    wait "$RESCUE_BOT_PID" 2>/dev/null || true
    RESCUE_BOT_PID=""
    log "Rescue bot stopped"
  fi
}

# --- Gateway health check ---
check_gateway() {
  if openclaw gateway status > /dev/null 2>&1; then
    return 0
  fi
  return 1
}

# --- Cleanup on exit ---
cleanup() {
  log "Watchdog shutting down..."
  stop_rescue_bot
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT

# --- Main loop ---
consecutive_failures=0

log "OpenClaw Rescue Watchdog started"
log "Check interval: ${CHECK_INTERVAL}s | Failure threshold: ${FAILURE_THRESHOLD}"

while true; do
  if check_gateway; then
    if [[ $consecutive_failures -gt 0 ]]; then
      log "Gateway recovered (was at ${consecutive_failures} consecutive failures)"
    fi
    consecutive_failures=0

    # If rescue bot is running but gateway is healthy, it will self-exit via its own health check
    # No need to kill it here — let it send its own shutdown message
  else
    consecutive_failures=$((consecutive_failures + 1))
    log "Gateway check failed (${consecutive_failures}/${FAILURE_THRESHOLD})"

    if [[ $consecutive_failures -ge $FAILURE_THRESHOLD ]]; then
      log "Failure threshold reached — attempting auto-repair..."

      # Run doctor --repair
      doctor_output=""
      doctor_exit=0
      doctor_output=$(openclaw doctor --repair --yes 2>&1) || doctor_exit=$?

      log "Doctor output: ${doctor_output}"

      # Give it a moment to recover
      sleep 5

      if check_gateway; then
        log "Gateway recovered via auto-repair"
        send_telegram "[OpenClaw] Gateway recovered via auto-repair after ${consecutive_failures} consecutive failures."
        consecutive_failures=0
      else
        log "Auto-repair failed — gateway still down"
        error_summary=$(echo "$doctor_output" | tail -20)
        send_telegram "[OpenClaw] Gateway is DOWN. Auto-repair failed.

Doctor output (last 20 lines):
${error_summary}

Rescue bot is being activated — use /help for commands."

        # Spawn rescue bot for manual intervention
        spawn_rescue_bot
      fi
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
