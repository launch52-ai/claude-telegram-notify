#!/usr/bin/env bash
# Claude Code hook script — sends Telegram notification when Claude needs attention.
# Handles: Stop, PermissionRequest, Notification (idle_prompt, elicitation_dialog)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from the script's directory if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

# Validate required env vars
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  exit 1
fi

# Machine name: env var or fallback to hostname
readonly MACHINE="${MACHINE_NAME:-$(hostname -s)}"

# Read hook input from stdin
readonly INPUT="$(cat)"

readonly HOOK_EVENT="$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"')"
readonly NOTIFICATION_TYPE="$(echo "$INPUT" | jq -r '.notification_type // ""')"
readonly SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // "unknown"')"
readonly CWD="$(echo "$INPUT" | jq -r '.cwd // "unknown"')"

# Extract short project path (last 3 segments, e.g. "Projects/Startups/my-app")
readonly PROJECT="$(echo "$CWD" | rev | cut -d'/' -f1-3 | rev)"

# Get git branch if inside a repo
BRANCH=""
if git -C "$CWD" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")"
fi

# ── Build title and context based on hook event ─────────────────────────────

CONTEXT=""

case "$HOOK_EVENT" in
  PermissionRequest)
    TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // ""')"

    if [[ "$TOOL_NAME" == "AskUserQuestion" ]]; then
      # Extract question and options
      MESSAGE="❓ *Claude is asking a question*"
      QUESTION="$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // ""')"
      OPTIONS="$(echo "$INPUT" | jq -r '.tool_input.questions[0].options[:4][] | "• *" + .label + "*: " + .description' 2>/dev/null || echo "")"
      if [[ -n "$QUESTION" ]]; then
        CONTEXT="${QUESTION}"
        if [[ -n "$OPTIONS" ]]; then
          CONTEXT="${CONTEXT}

${OPTIONS}"
        fi
      fi
    else
      # Permission request with tool details
      MESSAGE="🔐 *Claude needs permission*"
      TOOL_DESC="$(echo "$INPUT" | jq -r '.tool_input.description // ""')"
      TOOL_CMD="$(echo "$INPUT" | jq -r '.tool_input.command // ""')"

      if [[ -n "$TOOL_NAME" ]]; then
        if [[ -n "$TOOL_CMD" ]]; then
          CONTEXT="🔧 Tool: \`${TOOL_NAME}\`
💻 Command: \`${TOOL_CMD:0:150}\`"
        elif [[ -n "$TOOL_DESC" ]]; then
          CONTEXT="🔧 Tool: \`${TOOL_NAME}\`
📝 ${TOOL_DESC:0:200}"
        else
          CONTEXT="🔧 Tool: \`${TOOL_NAME}\`"
        fi
      fi
    fi
    ;;

  Notification)
    case "$NOTIFICATION_TYPE" in
      idle_prompt)
        MESSAGE="⏳ *Claude is waiting for your input*"
        ;;
      elicitation_dialog)
        MESSAGE="❓ *Claude is asking a question*"
        # Try to extract dialog content
        DIALOG_TITLE="$(echo "$INPUT" | jq -r '.title // ""')"
        DIALOG_BODY="$(echo "$INPUT" | jq -r '.body // ""')"
        DIALOG_MSG="$(echo "$INPUT" | jq -r '.message // ""')"
        if [[ -n "$DIALOG_TITLE" ]]; then
          CONTEXT="$DIALOG_TITLE"
          [[ -n "$DIALOG_BODY" ]] && CONTEXT="${CONTEXT}
${DIALOG_BODY:0:200}"
        elif [[ -n "$DIALOG_BODY" ]]; then
          CONTEXT="${DIALOG_BODY:0:250}"
        elif [[ -n "$DIALOG_MSG" ]]; then
          CONTEXT="${DIALOG_MSG:0:250}"
        fi
        ;;
      *)
        MESSAGE="🔔 *Claude needs your attention*"
        ;;
    esac
    ;;

  Stop)
    MESSAGE="✅ *Claude finished*"
    ;;

  *)
    MESSAGE="🔔 *Claude needs your attention*"
    ;;
esac

# ── Last user message from transcript ───────────────────────────────────────

LAST_MSG=""
if [[ "$HOOK_EVENT" == "Stop" || "$HOOK_EVENT" == "Notification" ]]; then
  if [[ "$CWD" != "unknown" && "$SESSION_ID" != "unknown" ]]; then
    SANITIZED_CWD="$(echo "$CWD" | tr '/' '-')"
    TRANSCRIPT="$HOME/.claude/projects/${SANITIZED_CWD}/${SESSION_ID}.jsonl"
    if [[ -f "$TRANSCRIPT" ]]; then
      LAST_MSG=$(jq -rs '
        [.[] | select(.type == "user") |
         select(.message.content | type == "string" or
                (type == "array" and any(.[]; .type == "text")))] |
        reverse |
        map(.message.content |
            if type == "string" then .
            else [.[] | select(.type == "text") | .text] | join(" ") end |
            gsub("\n"; " ") | gsub("  +"; " ")) |
        map(select(
            (startswith("[Request interrupted") | not) and
            (startswith("[Request cancelled") | not) and
            (startswith("This session is being continued") | not) and
            (. != "")
        )) |
        first // ""
      ' < "$TRANSCRIPT" 2>/dev/null || echo "")
      if [[ ${#LAST_MSG} -gt 200 ]]; then
        LAST_MSG="${LAST_MSG:0:197}..."
      fi
    fi
  fi
fi

# ── Tmux context ────────────────────────────────────────────────────────────

TMUX_INFO=""
TMUX_SESSION=""
TMUX_WINDOW=""
if [[ -n "${TMUX:-}" ]]; then
  TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "")
  TMUX_WINDOW=$(tmux display-message -p '#I:#W' 2>/dev/null || echo "")
  if [[ -n "$TMUX_SESSION" ]]; then
    TMUX_INFO="${TMUX_SESSION} → ${TMUX_WINDOW}"
  fi
fi

# Build MuxPod deep link via HTTPS redirect page
MUXPOD_LINK=""
REDIRECT_BASE="${MUXPOD_REDIRECT_URL:-https://launch52-ai.github.io/claude-telegram-notify}"
if [[ -n "${MUXPOD_DEEP_LINK_ID:-}" && -n "$TMUX_SESSION" ]]; then
  MUXPOD_URL="muxpod://connect?server=$(printf '%s' "$MUXPOD_DEEP_LINK_ID" | jq -sRr @uri)"
  MUXPOD_URL="${MUXPOD_URL}&session=$(printf '%s' "$TMUX_SESSION" | jq -sRr @uri)"
  if [[ -n "$TMUX_WINDOW" ]]; then
    WINDOW_NAME="${TMUX_WINDOW#*:}"
    MUXPOD_URL="${MUXPOD_URL}&window=$(printf '%s' "$WINDOW_NAME" | jq -sRr @uri)"
  fi
  # Wrap in HTTPS redirect page so Telegram makes it clickable
  ENCODED_MUXPOD=$(printf '%s' "$MUXPOD_URL" | jq -sRr @uri)
  MUXPOD_LINK="${REDIRECT_BASE}/#${MUXPOD_URL}"
fi

# ── Build final message ────────────────────────────────────────────────────

DETAILS="💻 Machine: \`${MACHINE}\`
📁 Project: \`${PROJECT}\`"

[[ -n "$BRANCH" ]] && DETAILS="${DETAILS}
🌿 Branch: \`${BRANCH}\`"

[[ -n "$TMUX_INFO" ]] && DETAILS="${DETAILS}
🖥 Tmux: \`${TMUX_INFO}\`"

[[ -n "$CONTEXT" ]] && DETAILS="${DETAILS}

${CONTEXT}"

[[ -n "$LAST_MSG" ]] && DETAILS="${DETAILS}
💬 Last prompt: ${LAST_MSG}"

readonly TEXT="${MESSAGE}

${DETAILS}"

# Build curl args
CURL_ARGS=(
  -s -X POST
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  -d "chat_id=${TELEGRAM_CHAT_ID}"
  --data-urlencode "text=${TEXT}"
  -d "parse_mode=Markdown"
  -d "disable_notification=false"
)

# Add MuxPod button if deep link is available
if [[ -n "$MUXPOD_LINK" ]]; then
  REPLY_MARKUP=$(jq -nc --arg url "$MUXPOD_LINK" '
    {inline_keyboard: [[{text: "📱 Open in MuxPod", url: $url}]]}
  ')
  CURL_ARGS+=(-d "reply_markup=${REPLY_MARKUP}")
fi

# Send via Telegram Bot API (fire-and-forget, don't block Claude)
curl "${CURL_ARGS[@]}" > /dev/null 2>&1 &

exit 0
