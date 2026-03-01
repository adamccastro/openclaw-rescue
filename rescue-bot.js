#!/usr/bin/env node
// OpenClaw Gateway Rescue Bot
// Minimal standalone Telegram bot — zero dependencies, only Node.js https module

const https = require('https');
const { execSync, exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const ADMIN_CHAT_ID = process.env.ADMIN_CHAT_ID;
const HEALTH_CHECK_INTERVAL = 60 * 1000; // 60 seconds
const POLL_TIMEOUT = 30; // Telegram long-poll seconds
const MAX_MSG_LEN = 4000;

if (!BOT_TOKEN || !ADMIN_CHAT_ID) {
  console.error('TELEGRAM_BOT_TOKEN and ADMIN_CHAT_ID environment variables are required');
  process.exit(1);
}

let updateOffset = 0;

// --- Telegram API helpers ---

function telegramApi(method, body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body || {});
    const opts = {
      hostname: 'api.telegram.org',
      path: `/bot${BOT_TOKEN}/${method}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
    };
    const req = https.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve({ ok: false, description: data }); }
      });
    });
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

async function sendMessage(chatId, text) {
  const chunks = chunkText(text, MAX_MSG_LEN);
  for (const chunk of chunks) {
    await telegramApi('sendMessage', { chat_id: chatId, text: chunk, parse_mode: 'HTML' });
  }
}

function chunkText(text, limit) {
  if (text.length <= limit) return [text];
  const chunks = [];
  let remaining = text;
  while (remaining.length > 0) {
    if (remaining.length <= limit) {
      chunks.push(remaining);
      break;
    }
    // Try to split at a newline near the limit
    let splitAt = remaining.lastIndexOf('\n', limit);
    if (splitAt < limit * 0.5) splitAt = limit; // no good newline, hard split
    chunks.push(remaining.slice(0, splitAt));
    remaining = remaining.slice(splitAt);
  }
  return chunks;
}

// --- Shell helpers ---

function runCommand(cmd, timeoutMs = 30000) {
  try {
    const output = execSync(cmd, { encoding: 'utf8', timeout: timeoutMs, env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' } });
    return output || '(no output)';
  } catch (err) {
    return `Error: ${err.stderr || err.message || String(err)}`;
  }
}

// --- Command handlers ---

function cmdDoctor() {
  return `<b>Running openclaw doctor --repair --yes ...</b>\n\n<pre>${escapeHtml(runCommand('openclaw doctor --repair --yes', 60000))}</pre>`;
}

function cmdLogs() {
  const today = new Date();
  const dateStr = today.toISOString().slice(0, 10).replace(/-/g, '');
  const logDir = '/tmp/openclaw';
  try {
    const files = fs.readdirSync(logDir).filter((f) => f.startsWith('openclaw-') && f.includes(dateStr) && f.endsWith('.log'));
    if (files.length === 0) {
      // Try looser match — any log file modified today
      const allLogs = fs.readdirSync(logDir).filter((f) => f.endsWith('.log')).sort((a, b) => {
        return fs.statSync(path.join(logDir, b)).mtimeMs - fs.statSync(path.join(logDir, a)).mtimeMs;
      });
      if (allLogs.length === 0) return '<b>No log files found in /tmp/openclaw/</b>';
      const target = path.join(logDir, allLogs[0]);
      return `<b>Latest log: ${allLogs[0]}</b>\n<pre>${escapeHtml(tailFile(target, 50))}</pre>`;
    }
    let output = '';
    for (const f of files.slice(0, 3)) {
      const fp = path.join(logDir, f);
      output += `<b>${f}</b>\n<pre>${escapeHtml(tailFile(fp, 50))}</pre>\n`;
    }
    return output;
  } catch (err) {
    return `<b>Error reading logs:</b> <pre>${escapeHtml(String(err))}</pre>`;
  }
}

function tailFile(filePath, lines) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const allLines = content.split('\n');
    return allLines.slice(-lines).join('\n') || '(empty)';
  } catch (err) {
    return `Error: ${err.message}`;
  }
}

function cmdRestart() {
  return `<b>Restarting gateway...</b>\n\n<pre>${escapeHtml(runCommand('openclaw gateway restart', 30000))}</pre>`;
}

function cmdStatus() {
  return `<b>Gateway Status:</b>\n\n<pre>${escapeHtml(runCommand('openclaw gateway status'))}</pre>`;
}

function cmdConfig() {
  const configPath = path.join(process.env.HOME || '/Users/adamcastro', '.openclaw', 'openclaw.json');
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const redacted = redactSecrets(raw);
    return `<b>openclaw.json (redacted):</b>\n<pre>${escapeHtml(redacted)}</pre>`;
  } catch (err) {
    return `<b>Error reading config:</b> <pre>${escapeHtml(String(err))}</pre>`;
  }
}

function redactSecrets(jsonStr) {
  // Redact values for keys containing token, password, secret, key, api_key etc.
  const sensitivePattern = /(token|password|passwd|secret|api_key|apikey|auth|credential)/i;
  try {
    const obj = JSON.parse(jsonStr);
    const redact = (o) => {
      if (typeof o !== 'object' || o === null) return o;
      if (Array.isArray(o)) return o.map(redact);
      const result = {};
      for (const [k, v] of Object.entries(o)) {
        if (sensitivePattern.test(k) && typeof v === 'string' && v.length > 4) {
          result[k] = v.slice(0, 4) + '***';
        } else if (typeof v === 'object') {
          result[k] = redact(v);
        } else {
          result[k] = v;
        }
      }
      return result;
    };
    return JSON.stringify(redact(obj), null, 2);
  } catch {
    // Fallback: regex-based redaction on raw string
    return jsonStr.replace(/"(token|password|passwd|secret|api_key|apikey|auth|credential)":\s*"(.{4})[^"]*"/gi, '"$1": "$2***"');
  }
}

function cmdHelp() {
  return [
    '<b>OpenClaw Rescue Bot Commands</b>',
    '',
    '/doctor  — Run openclaw doctor --repair --yes',
    '/logs    — Tail today\'s gateway logs (last 50 lines)',
    '/restart — Restart the gateway',
    '/status  — Show gateway status',
    '/config  — Show openclaw.json (secrets redacted)',
    '/help    — Show this help message',
  ].join('\n');
}

function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// --- Main polling loop ---

async function pollUpdates() {
  while (true) {
    try {
      const res = await telegramApi('getUpdates', { offset: updateOffset, timeout: POLL_TIMEOUT });
      if (res.ok && res.result && res.result.length > 0) {
        for (const update of res.result) {
          updateOffset = update.update_id + 1;
          await handleUpdate(update);
        }
      }
    } catch (err) {
      console.error('Poll error:', err.message);
      await sleep(5000);
    }
  }
}

async function handleUpdate(update) {
  const msg = update.message;
  if (!msg || !msg.text) return;

  const chatId = String(msg.chat.id);
  if (chatId !== String(ADMIN_CHAT_ID)) {
    console.log(`Ignoring message from unauthorized chat: ${chatId}`);
    return;
  }

  const text = msg.text.trim();
  const cmd = text.split(/\s+/)[0].toLowerCase().replace(/@\w+$/, ''); // strip @botname

  console.log(`Command: ${cmd}`);

  let response;
  switch (cmd) {
    case '/doctor':  response = cmdDoctor(); break;
    case '/logs':    response = cmdLogs(); break;
    case '/restart': response = cmdRestart(); break;
    case '/status':  response = cmdStatus(); break;
    case '/config':  response = cmdConfig(); break;
    case '/help':
    case '/start':   response = cmdHelp(); break;
    default:         response = `Unknown command: ${escapeHtml(cmd)}\nType /help for available commands.`; break;
  }

  await sendMessage(chatId, response);
}

// --- Health check: auto-exit when gateway recovers ---

function checkGatewayHealth() {
  try {
    const output = execSync('openclaw gateway status', {
      encoding: 'utf8',
      timeout: 15000,
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
    });
    // Consider healthy if status command succeeds and output contains positive indicators
    const healthy = /running|healthy|online|active/i.test(output);
    if (healthy) {
      console.log('Gateway is healthy — rescue bot shutting down');
      sendMessage(ADMIN_CHAT_ID, 'Gateway is back online, rescue bot shutting down.').then(() => {
        process.exit(0);
      }).catch(() => {
        process.exit(0);
      });
    }
  } catch {
    // Gateway still down — keep running
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// --- Startup ---

(async () => {
  console.log('OpenClaw Rescue Bot starting...');
  console.log(`Admin chat ID: ${ADMIN_CHAT_ID}`);

  await sendMessage(ADMIN_CHAT_ID, 'OpenClaw Rescue Bot is online. Gateway appears to be down.\nType /help for available commands.');

  // Start health check interval
  setInterval(checkGatewayHealth, HEALTH_CHECK_INTERVAL);

  // Start polling
  await pollUpdates();
})();
