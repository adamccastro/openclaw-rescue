# OpenClaw Rescue System

A watchdog + emergency Telegram bot that keeps your OpenClaw gateway accessible even when the gateway itself is down.

## The Problem

When the OpenClaw gateway crashes due to a bad config or other issue, your AI agent becomes unreachable. You're locked out of the very tool that could help you fix it.

## The Solution

```
┌─────────────────────────────┐
│   openclaw-rescue.sh        │  ← launchd watchdog (always running)
│   • Checks gateway every 30s│
│   • Auto-runs doctor on fail│
│   • Alerts via Telegram     │
└──────────┬──────────────────┘
           │ gateway down + doctor fails
           ▼
┌─────────────────────────────┐
│   rescue-bot.js             │  ← minimal Telegram bot
│   • /doctor  → run doctor   │
│   • /logs    → tail logs    │
│   • /restart → restart gw   │
│   • /status  → system info  │
│   • /config  → show config  │
│   Auto-exits when gateway   │
│   comes back healthy        │
└─────────────────────────────┘
```

## How It Works

1. **Watchdog** (`openclaw-rescue.sh`) runs as a launchd agent, checking gateway health every 30 seconds
2. After **3 consecutive failures**, it runs `openclaw doctor --repair --yes`
3. If doctor **fixes it**: sends a Telegram alert — "Gateway recovered via auto-repair"
4. If doctor **fails**: sends a Telegram alert with the error, then spawns the rescue bot
5. **Rescue bot** (`rescue-bot.js`) connects to Telegram using the same bot token and gives you a remote CLI
6. When the gateway comes back online, the rescue bot **auto-exits** (checks every 60s)

## Install

```bash
cd openclaw-rescue
bash install.sh
```

This will:
- Create `~/.openclaw/rescue.env` with your bot token and chat ID
- Copy the launchd plist to `~/Library/LaunchAgents/`
- Start the watchdog immediately

## Configuration

Edit `~/.openclaw/rescue.env`:
```bash
BOT_TOKEN="your-telegram-bot-token"
ADMIN_CHAT_ID="your-telegram-user-id"
```

## Rescue Bot Commands

These are only available when the gateway is down and the rescue bot is active:

| Command    | Description                              |
|------------|------------------------------------------|
| `/doctor`  | Run `openclaw doctor --repair --yes`     |
| `/logs`    | Tail last 50 lines of gateway logs       |
| `/restart` | Run `openclaw gateway restart`           |
| `/status`  | Show `openclaw gateway status`           |
| `/config`  | Show openclaw.json (secrets redacted)    |
| `/help`    | List available commands                  |

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/ai.openclaw.rescue.plist
rm ~/Library/LaunchAgents/ai.openclaw.rescue.plist
```

## Files

| File                      | Purpose                           |
|---------------------------|-----------------------------------|
| `openclaw-rescue.sh`      | Watchdog script (health checker)  |
| `rescue-bot.js`           | Emergency Telegram bot            |
| `ai.openclaw.rescue.plist`| launchd agent config              |
| `install.sh`              | One-command installer             |

## Logs

- Watchdog: `/tmp/openclaw/rescue.log`
- launchd: `~/.openclaw/logs/rescue.log`

## Security

- Rescue bot only responds to the configured `ADMIN_CHAT_ID`
- `rescue.env` is created with `600` permissions
- Config display redacts all tokens/passwords/secrets
- The rescue bot shares the same Telegram bot token as OpenClaw (it only activates when the gateway is down, so there's no conflict)

## Note on Bot Token Sharing

The rescue bot uses the same Telegram bot token as OpenClaw. This works because:
- The rescue bot only starts when the gateway is **down** (not polling Telegram)
- The rescue bot auto-exits when the gateway comes **back up**
- There's no conflict since only one process polls at a time
