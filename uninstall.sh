#!/usr/bin/env bash
# Removes the Telegram notification hook from Claude Code's global settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_SCRIPT="$SCRIPT_DIR/notify.sh"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "No settings file found. Nothing to uninstall."
  exit 0
fi

readonly UPDATED=$(jq --arg cmd "$HOOK_SCRIPT" '
  def remove_hook(event_name):
    if .hooks[event_name] then
      .hooks[event_name] |= map(select(.hooks | all(.command != $cmd)))
    else . end;

  remove_hook("Stop") |
  remove_hook("PermissionRequest") |
  remove_hook("Notification")
' "$SETTINGS_FILE")

echo "$UPDATED" > "$SETTINGS_FILE"

echo "✅ Telegram notification hook removed."
