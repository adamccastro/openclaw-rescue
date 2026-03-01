#!/usr/bin/env bash
# OpenClaw Rescue System Installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="ai.openclaw.rescue"
PLIST_SRC="${SCRIPT_DIR}/${PLIST_NAME}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
RESCUE_ENV="${HOME}/.openclaw/rescue.env"
LOG_DIR="${HOME}/.openclaw/logs"

echo "🦞 OpenClaw Rescue System Installer"
echo "===================================="
echo ""

# Create log directory
mkdir -p "$LOG_DIR"

# Create rescue.env if it doesn't exist
if [[ ! -f "$RESCUE_ENV" ]]; then
  cat > "$RESCUE_ENV" << 'ENVEOF'
# OpenClaw Rescue Bot Configuration
# These credentials are used by the watchdog and rescue bot

BOT_TOKEN="8318710080:AAEhMcEkoW9YivhWjCo4vBxEryflFmhxgPY"
ADMIN_CHAT_ID="1967737232"
ENVEOF
  chmod 600 "$RESCUE_ENV"
  echo "✅ Created ${RESCUE_ENV}"
  echo "   Bot token and admin chat ID pre-configured."
else
  echo "ℹ️  ${RESCUE_ENV} already exists — skipping."
fi

echo ""

# Make scripts executable
chmod +x "${SCRIPT_DIR}/rescue-bot.js"
chmod +x "${SCRIPT_DIR}/openclaw-rescue.sh"
echo "✅ Scripts marked executable"

# Unload existing plist if loaded
if launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
  echo "⏳ Unloading existing ${PLIST_NAME}..."
  launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# Copy plist
cp "$PLIST_SRC" "$PLIST_DST"
echo "✅ Copied plist to ${PLIST_DST}"

# Load the agent
launchctl load "$PLIST_DST"
echo "✅ Loaded ${PLIST_NAME}"

echo ""
echo "===================================="
echo "🟢 OpenClaw Rescue System is active!"
echo ""
echo "What it does:"
echo "  • Monitors gateway health every 30 seconds"
echo "  • After 3 consecutive failures: runs 'openclaw doctor --repair'"
echo "  • If doctor can't fix it: sends you a Telegram alert"
echo "  • Spawns a rescue bot so you can debug remotely via Telegram"
echo ""
echo "Rescue bot commands (only active when gateway is down):"
echo "  /doctor  — Run openclaw doctor --repair"
echo "  /logs    — Tail gateway logs"
echo "  /restart — Restart the gateway"
echo "  /status  — Show gateway status"
echo "  /config  — Show config (secrets redacted)"
echo "  /help    — List commands"
echo ""
echo "Logs: ${LOG_DIR}/rescue.log"
echo "       /tmp/openclaw/rescue.log"
echo ""
echo "To uninstall:"
echo "  launchctl unload ${PLIST_DST}"
echo "  rm ${PLIST_DST}"
