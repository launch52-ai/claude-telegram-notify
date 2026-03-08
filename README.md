# Claude Code → Telegram Notifications

Get Telegram notifications when Claude Code finishes a task, needs permission, asks a question, or is waiting for your input.

Uses Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to send messages via the Telegram Bot API.

## Hook Events

| Hook | When it fires | What you see |
|------|--------------|--------------|
| `Stop` | Claude finishes responding | Last prompt from transcript |
| `PermissionRequest` | Claude needs tool approval | Tool name + command/description |
| `PermissionRequest` | Claude asks a question (`AskUserQuestion`) | Question text + options |
| `Notification` (`idle_prompt`) | Claude is idle, waiting for input | Last prompt from transcript |
| `Notification` (`elicitation_dialog`) | Claude shows a dialog/question | Dialog content |

## Setup

### 1. Create a Telegram Bot

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot` and follow the prompts
3. Copy the bot token

### 2. Install

```bash
./install.sh
```

The installer walks you through everything:
- Paste your bot token
- Send a message to your bot — it auto-detects your chat ID
- Name your machine (defaults to hostname)
- Optionally configure [MuxPod](https://github.com/moezakura/mux-pod) deep linking
- Sends a test notification to verify
- Installs hooks into `~/.claude/settings.json` (global, applies to all projects)

## Uninstall

```bash
./uninstall.sh
```

## Multi-Machine Setup

One bot, one chat ID — just set a different `MACHINE_NAME` on each Mac so you know which one pinged you.

**Mac 1 (.env):**
```
TELEGRAM_BOT_TOKEN=same-token
TELEGRAM_CHAT_ID=same-chat-id
MACHINE_NAME=MacBook Pro
```

**Mac 2 (.env):**
```
TELEGRAM_BOT_TOKEN=same-token
TELEGRAM_CHAT_ID=same-chat-id
MACHINE_NAME=Mac Mini
```

If `MACHINE_NAME` is not set, it falls back to the system hostname.

## What's In a Notification

Each message includes:
- **Machine name** — which Mac sent it
- **Project path** — last 3 segments of the working directory
- **Git branch** — current branch (if in a git repo)
- **Tmux context** — session and window name (if running in tmux)
- **Tool details** — tool name + command for permission requests
- **Question + options** — for AskUserQuestion prompts
- **Last prompt** — your most recent message to Claude (for Stop/idle events)
- **MuxPod link** — tappable deep link to open the terminal in MuxPod (optional)

## How It Works

Claude Code fires hook events at key moments. The `notify.sh` script:

1. Reads the hook JSON from stdin
2. Determines the event type and extracts relevant context
3. For permission requests: shows tool name, command, or question details
4. For stop/idle: reads the last user message from the session transcript
5. Sends a formatted message to your Telegram chat
6. Runs asynchronously (non-blocking) so it doesn't slow down Claude

## MuxPod Integration (Optional)

If you use [MuxPod](https://github.com/moezakura/mux-pod) as a mobile tmux client, notifications can include a tappable deep link that opens the terminal directly in the app.

During install, enter your MuxPod **Deep Link ID** (from MuxPod's connection settings). The notification will include a link like:

```
🔗 Open in MuxPod → muxpod://connect?server=macbook-pro&session=dev&window=claude
```

Set `MUXPOD_DEEP_LINK_ID=` in `.env` to match the ID configured in MuxPod. Leave empty to disable.

## Manual Hook Configuration

If you prefer to configure manually, add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/notify.sh" }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/notify.sh" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt|elicitation_dialog",
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/notify.sh" }
        ]
      }
    ]
  }
}
```
