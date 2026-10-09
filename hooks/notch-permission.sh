#!/bin/bash
# PermissionRequest hook: shows Allow / Deny in the notch and waits for your answer.
# The terminal prompt still appears as usual; whichever you answer first wins.
# Prints the decision JSON if you answered in the notch; prints nothing otherwise (normal flow).

input=$(cat)
[ -n "${NOTCHPET_INTERNAL:-}" ] && exit 0
SOCK="${NOTCHPET_SOCKET:-$HOME/Library/Application Support/NotchPet/notch.sock}"
[ -S "$SOCK" ] || exit 0

agent="claude"
[ "${1:-}" = "--codex" ] && agent="codex"

CONFIG="$HOME/Library/Application Support/NotchPet/config.json"
wait=$(jq -r '.approvalWaitSeconds // 120' "$CONFIG" 2>/dev/null || echo 120)
wait=${wait%.*}

tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
case "$tty" in ""|"??") tty="" ;; *) tty="/dev/$tty" ;; esac

# The app hosting the session (see notch-hook.sh).
host=""
pid=$PPID
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
  cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
  case "$cmd" in */*.app/Contents/*) host="${cmd%%.app/Contents/*}.app"; break ;; esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

payload=$(printf '%s' "$input" | jq -c --arg agent "$agent" --arg program "${TERM_PROGRAM:-}" --arg tty "$tty" --arg host "$host" \
  '. + {notch_agent: $agent, notch_terminal: {program: $program, tty: $tty, host_app: $host}}' 2>/dev/null) || exit 0

out=$(curl -s --max-time $((wait + 5)) --unix-socket "$SOCK" \
  -H 'Content-Type: application/json' --data-binary "$payload" \
  http://localhost/permission 2>/dev/null)
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
