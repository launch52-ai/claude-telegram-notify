#!/usr/bin/env bash
# Installs the Telegram notification hook into Claude Code's global settings.
# Interactively configures .env if needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_SCRIPT="$SCRIPT_DIR/notify.sh"
ENV_FILE="$SCRIPT_DIR/.env"

# Ensure notify.sh is executable
chmod +x "$HOOK_SCRIPT"

# ── .env setup ──────────────────────────────────────────────────────────────

_load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
  fi
}

_save_env() {
  cat > "$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
MACHINE_NAME=${MACHINE_NAME}
MUXPOD_DEEP_LINK_ID=${MUXPOD_DEEP_LINK_ID:-}
EOF
}

_prompt_value() {
  local var_name="$1" prompt_text="$2" default="$3" current_value
  current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    read -rp "$prompt_text [$current_value]: " input
    printf -v "$var_name" '%s' "${input:-$current_value}"
  elif [[ -n "$default" ]]; then
    read -rp "$prompt_text ($default): " input
    printf -v "$var_name" '%s' "${input:-$default}"
  else
    while true; do
      read -rp "$prompt_text: " input
      if [[ -n "$input" ]]; then
        printf -v "$var_name" '%s' "$input"
        break
      fi
      echo "  This field is required."
    done
  fi
}

_load_env

echo "╔══════════════════════════════════════════════════╗"
echo "║   Claude Code → Telegram Notifications Setup    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Bot token
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "Step 1: Telegram Bot Token"
  echo "  → Open Telegram, message @BotFather"
  echo "  → Send /newbot and follow the prompts"
  echo "  → Copy the token it gives you"
  echo ""
fi
_prompt_value TELEGRAM_BOT_TOKEN "Bot token" ""

echo ""

# Chat ID — auto-detect from bot's getUpdates
if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "Step 2: Your Telegram Chat ID"
  echo ""
  echo "  → Open Telegram and find your bot"
  echo "  → Send it any message (e.g. \"hello\")"
  echo ""
  read -rp "Press Enter once you've sent the message..." _

  echo "  Waiting for your message..."

  # Poll getUpdates with 10s Telegram long polling
  UPDATES=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=10" 2>/dev/null)
  API_OK=$(echo "$UPDATES" | jq -r '.ok // false')

  if [[ "$API_OK" != "true" ]]; then
    echo "  ✗ Failed to reach Telegram API. Is the bot token correct?"
    echo "  Falling back to manual entry."
    echo "  → Message @userinfobot on Telegram to get your chat ID"
    echo ""
    _prompt_value TELEGRAM_CHAT_ID "Chat ID" ""
  else
    # Get all unique chats from recent messages
    CHATS=$(echo "$UPDATES" | jq -r '
      [.result[] | .message // empty |
       {id: .chat.id, name: (.chat.first_name + " " + (.chat.last_name // "") | rtrimstr(" ")), username: (.chat.username // "")}] |
      unique_by(.id)
    ')
    CHAT_COUNT=$(echo "$CHATS" | jq 'length')

    if [[ "$CHAT_COUNT" -eq 0 ]]; then
      echo "  ✗ No messages found. Make sure you sent a message to the bot."
      echo "  Falling back to manual entry."
      echo "  → Message @userinfobot on Telegram to get your chat ID"
      echo ""
      _prompt_value TELEGRAM_CHAT_ID "Chat ID" ""
    elif [[ "$CHAT_COUNT" -eq 1 ]]; then
      TELEGRAM_CHAT_ID=$(echo "$CHATS" | jq -r '.[0].id')
      CHAT_NAME=$(echo "$CHATS" | jq -r '.[0].name')
      CHAT_USER=$(echo "$CHATS" | jq -r '.[0].username')
      echo "  ✓ Found: ${CHAT_NAME} (@${CHAT_USER}) — ID: ${TELEGRAM_CHAT_ID}"
    else
      echo "  Found multiple chats:"
      echo ""
      for i in $(seq 0 $((CHAT_COUNT - 1))); do
        CHAT_NAME=$(echo "$CHATS" | jq -r ".[$i].name")
        CHAT_USER=$(echo "$CHATS" | jq -r ".[$i].username")
        CHAT_ID=$(echo "$CHATS" | jq -r ".[$i].id")
        echo "  $((i + 1))) ${CHAT_NAME} (@${CHAT_USER}) — ID: ${CHAT_ID}"
      done
      echo ""
      while true; do
        read -rp "  Pick a number [1-${CHAT_COUNT}]: " pick
        if [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le "$CHAT_COUNT" ]]; then
          TELEGRAM_CHAT_ID=$(echo "$CHATS" | jq -r ".[$((pick - 1))].id")
          break
        fi
        echo "  Invalid choice."
      done
    fi
  fi
else
  echo "Step 2: Chat ID"
  read -rp "Chat ID [$TELEGRAM_CHAT_ID]: " input
  TELEGRAM_CHAT_ID="${input:-$TELEGRAM_CHAT_ID}"
fi

echo ""

# Machine name
echo "Step 3: Name for this machine (shown in notifications)"
_prompt_value MACHINE_NAME "Machine name" "$(hostname -s)"

echo ""

# MuxPod deep link (optional)
echo "Step 4: MuxPod deep link (optional)"
echo "  If you use MuxPod (tmux client for mobile), enter the"
echo "  Deep Link ID from your MuxPod connection settings."
echo "  Leave empty to skip."
echo ""
read -rp "MuxPod Deep Link ID [${MUXPOD_DEEP_LINK_ID:-}]: " input
MUXPOD_DEEP_LINK_ID="${input:-${MUXPOD_DEEP_LINK_ID:-}}"

echo ""

# Save .env
_save_env
echo "✓ Saved .env"

# ── Test notification ───────────────────────────────────────────────────────

echo ""
read -rp "Send a test notification? [Y/n]: " test_choice
if [[ "${test_choice:-Y}" =~ ^[Yy]?$ ]]; then
  echo "  Sending..."
  TEST_RESULT=$(echo "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"session_id\":\"test\",\"cwd\":\"$(pwd)\"}" | "$HOOK_SCRIPT" 2>&1) || true
  # Give the background curl a moment
  sleep 1
  echo "  ✓ Test notification sent — check Telegram!"
  echo ""
  read -rp "Did you receive it? [Y/n]: " received
  if [[ "${received:-Y}" =~ ^[Nn]$ ]]; then
    echo ""
    echo "  Troubleshooting:"
    echo "  • Make sure you messaged the bot first (open a chat with it)"
    echo "  • Verify the bot token is correct"
    echo "  • Verify the chat ID is correct (must be numeric)"
    echo "  • Re-run ./install.sh to update values"
    echo ""
    read -rp "Continue with installation anyway? [y/N]: " cont
    if [[ ! "${cont:-N}" =~ ^[Yy]$ ]]; then
      echo "Installation aborted. Re-run ./install.sh when ready."
      exit 1
    fi
  fi
fi

# ── Hook installation ──────────────────────────────────────────────────────

# Ensure .claude directory exists
mkdir -p "$HOME/.claude"

# Create settings file if it doesn't exist
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Build hook entries for each event type
readonly HOOK_CMD=$(cat <<EOF
{"type": "command", "command": "$HOOK_SCRIPT"}
EOF
)

# Merge into existing settings using jq
readonly UPDATED=$(jq --arg cmd "$HOOK_SCRIPT" '
  def ensure_hook(event_name; entry):
    .hooks[event_name] //= [] |
    if (.hooks[event_name] | map(select(.hooks[]?.command == $cmd)) | length) > 0
    then .
    else .hooks[event_name] += [entry]
    end;

  # Stop — task finished
  ensure_hook("Stop"; {hooks: [{type: "command", command: $cmd}]}) |

  # PermissionRequest — permission + AskUserQuestion with tool details
  ensure_hook("PermissionRequest"; {hooks: [{type: "command", command: $cmd}]}) |

  # Notification — idle and elicitation dialog (not permission_prompt, handled above)
  ensure_hook("Notification"; {matcher: "idle_prompt|elicitation_dialog", hooks: [{type: "command", command: $cmd}]})
' "$SETTINGS_FILE")

echo "$UPDATED" > "$SETTINGS_FILE"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║            ✅ Installation complete!             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Machine:  ${MACHINE_NAME}"
echo "  Hook:     ${HOOK_SCRIPT}"
echo ""
echo "  Notifications for:"
echo "    • Task finished (Stop)"
echo "    • Permission requests with tool details"
echo "    • Questions (AskUserQuestion, elicitation)"
echo "    • Idle prompt"
echo ""
echo "  To reconfigure: ./install.sh"
echo "  To remove:      ./uninstall.sh"
