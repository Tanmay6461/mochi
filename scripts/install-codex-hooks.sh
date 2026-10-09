#!/bin/bash
# Adds NotchPet hooks to Codex (~/.codex/config.toml). Backs the file up first; safe to re-run.
# Codex asks you to trust new hooks: run `/hooks` inside Codex once after installing.
set -euo pipefail

HOOKS="$(cd "$(dirname "$0")/../hooks" && pwd)"
CONFIG="$HOME/.codex/config.toml"
mkdir -p "$HOME/.codex"
touch "$CONFIG"
cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"

# Drop any block we wrote before, then append a fresh one.
sed -i '' '/^# >>> notchpet >>>$/,/^# <<< notchpet <<<$/d' "$CONFIG"
{
  echo "# >>> notchpet >>>"
  for event in SessionStart UserPromptSubmit PostToolUse Stop SessionEnd; do
    printf '[[hooks.%s]]\n[[hooks.%s.hooks]]\ntype = "command"\ncommand = "%s --codex"\ntimeout = 3\n\n' \
      "$event" "$event" "$HOOKS/notch-hook.sh"
  done
  printf '[[hooks.PermissionRequest]]\n[[hooks.PermissionRequest.hooks]]\ntype = "command"\ncommand = "%s --codex"\ntimeout = 600\n' \
    "$HOOKS/notch-permission.sh"
  echo "# <<< notchpet <<<"
} >> "$CONFIG"
echo "Added NotchPet hooks to $CONFIG. Run /hooks in Codex to trust them."
