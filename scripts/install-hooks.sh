#!/bin/bash
# Registers NotchPet's hooks in ~/.claude/settings.json.
# Backs up the file first and is safe to re-run (replaces its own entries only).
set -euo pipefail

HOOKS="$(cd "$(dirname "$0")/../hooks" && pwd)"
HOOK="$HOOKS/notch-hook.sh"
PERM="$HOOKS/notch-permission.sh"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

tmp=$(mktemp)
jq --arg cmd "$HOOK" --arg perm "$PERM" '
  def entry: {hooks: [{type: "command", command: $cmd, async: true, timeout: 5}]};
  def strip: map(select(any(.hooks[]?; .command == $cmd or .command == $perm) | not));
  .hooks //= {}
  | reduce ("SessionStart","UserPromptSubmit","PostToolUse","Stop","SessionEnd") as $e
      (.; .hooks[$e] = ((.hooks[$e] // []) | strip) + [entry])
  | .hooks.Notification = ((.hooks.Notification // []) | strip)
      + [entry + {matcher: "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"}]
  | .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) | strip)
      + [{hooks: [{type: "command", command: $perm, timeout: 600}]}]
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"
echo "Installed NotchPet hooks into $SETTINGS (backup saved next to it)."
