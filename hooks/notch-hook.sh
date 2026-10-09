#!/bin/bash
# Forwards a Claude Code (or Codex, with --codex) hook event (JSON on stdin) to the NotchPet app.
# Must never slow down or break the agent: short timeout, always exit 0.

input=$(cat)
[ -n "${NOTCHPET_INTERNAL:-}" ] && exit 0   # NotchPet's own summary calls
SOCK="${NOTCHPET_SOCKET:-$HOME/Library/Application Support/NotchPet/notch.sock}"
[ -S "$SOCK" ] || exit 0

agent="claude"
[ "${1:-}" = "--codex" ] && agent="codex"

# Which terminal tab is this session in? Lets the app jump back to it later.
tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
case "$tty" in ""|"??") tty="" ;; *) tty="/dev/$tty" ;; esac

# Which app is hosting the session (Terminal, iTerm, the Claude or Codex desktop app, VS Code...)?
# Walk up the process tree to the first ancestor that lives inside a .app bundle.
host=""
pid=$PPID
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
  cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
  case "$cmd" in */*.app/Contents/*) host="${cmd%%.app/Contents/*}.app"; break ;; esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

payload=$(printf '%s' "$input" | jq -c \
  --arg agent "$agent" \
  --arg program "${TERM_PROGRAM:-}" \
  --arg iterm "${ITERM_SESSION_ID:-}" \
  --arg term "${TERM_SESSION_ID:-}" \
  --arg tty "$tty" \
  --arg host "$host" \
  '. + {notch_agent: $agent, notch_terminal: {program: $program, iterm_session_id: $iterm, term_session_id: $term, tty: $tty, host_app: $host}}' 2>/dev/null) || exit 0

curl -s -o /dev/null --max-time 0.5 --unix-socket "$SOCK" \
  -H 'Content-Type: application/json' --data-binary "$payload" \
  http://localhost/event >/dev/null 2>&1
exit 0
