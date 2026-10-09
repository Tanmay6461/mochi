# NotchPet

Lives in the MacBook notch. Watches your Claude Code and Codex sessions (and any long shell job),
lets you answer their permission prompts without switching windows, and switches between apps
and whole projects from the notch.

    Claude Code / Codex hooks ──▶ hooks/*.sh ──HTTP over unix socket──▶ NotchPet.app
    bin/notch-run <cmd>       ──┘

## Setup

    scripts/bundle.sh --open          # build build/NotchPet.app and launch it
    scripts/install-hooks.sh          # Claude Code hooks in ~/.claude/settings.json (backed up)
    scripts/install-codex-hooks.sh    # Codex hooks in ~/.codex/config.toml (backed up); then /hooks in Codex to trust them

First time you open the panel, click "Allow Accessibility" (needed to see other apps' windows).
macOS will also ask once per terminal/browser to let NotchPet control it.

### Fixed signing (so permissions survive rebuilds)

Ad-hoc signing gives every build a new identity, and macOS silently drops Accessibility for it
(the list still shows NotchPet switched on, but `chat-watcher.json` says `"trusted": false`).
One-time fix:

1. Keychain Access → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `NotchPet Local Signing` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** → Create.
3. `scripts/bundle.sh --open` (if asked whether codesign may use the key, choose **Always Allow**).
4. System Settings → Privacy & Security → Accessibility: remove NotchPet (−), add `build/NotchPet.app` (+), switch it on,
   then quit and reopen NotchPet. From now on rebuilds keep the permission.

## The pet

A squishy 3D mochi (SceneKit) lives in the notch's left ear. Its face shows the mood:

| mood | face |
|---|---|
| idle | ● ● and a little smile; winks, glances around, wiggles, yawns now and then |
| working | reading side to side, gently swaying; green glow and a pulsing green dot in the right ear |
| finished | ^ ^ ω, hops and sparkles |
| needs you | big ● ● and an open mouth, bounces with a "!"; faster and bigger the longer you wait |
| sleeping (nothing for 15 min) | ‿ ‿, floating z's |

**It's a virtual pet:** it munches a treat each time you check on finished work, gets happier when you rub it
with the cursor (> < ω), jiggles when you click it, and gets sad if agents sit blocked on you for too long.
Its name shows in the panel; change its color (peach, strawberry, matcha, taro, lemon, soda) from the ⋯ menu.

- **At a glance**: a pulsing green dot in the right ear (with a count) whenever something is running; a count badge when something needs you.
- **Click the notch** (anywhere on it) to open the panel; click it again, press Esc, or click elsewhere to close.
  Nothing opens on hover. The panel has two cards, **ChatGPT** (chats + Codex) and **Claude** (Claude Desktop chats +
  Claude Code sessions), filtered by *What needs me?* · *Where did I leave off?*; 4 rows each, then *See more*.
  Click a row to open that exact chat or session. What's running now is listed in green, with how long.
- **Only permission prompts drop down on their own** (Allow / Always / Deny), since an agent is blocked until you answer.
  Finished work is quiet: the pet hops and the badge counts it.
- **Scroll on the notch** to flip through recent apps. After 5 min blocked the notch pulses; after 15, a phone push (if configured).
- **Stays out of the way:** hidden over fullscreen apps (videos, slides, games) except for permission prompts; stays on
  the notch display instead of following the cursor (`followCursorAcrossDisplays` to change). The pet in the notch is
  a still picture of the 3D pet (rendered once per mood and color, then cached), which blinks and hops by swapping
  pictures, so it costs nothing while it sits there. The live 3D pet only runs while the panel is open.

`NotchPet --render-pet <dir>` renders the moods to PNG (handy when tweaking the look).

## Hotkeys

- **⌃⌥Space**: open or close the panel
- **⌃⌥J**: jump to the session that has waited on you longest

Change them in `config.json` (`hotkeyOpen`, `hotkeyJump`, e.g. `"cmd+shift+m"`), or set `""` to turn one off.

## Long jobs

    bin/notch-run npm run build
    bin/notch-run -n "train v2" python train.py

Shows as working in the notch, then ✓/✗ with the duration when it exits.

## Settings

`~/Library/Application Support/NotchPet/config.json` (written with defaults on first launch; restart to apply):

| key | default | |
|---|---|---|
| `ntfyTopic` | null | ntfy.sh topic for phone pushes; install the ntfy app and subscribe |
| `escalateAfterMinutes` / `pushAfterMinutes` | 5 / 15 | |
| `summaries`, `summaryModel` | true, haiku | runs `claude -p` with your login, ~$0.001 each, not saved to history |
| `approvalsFromNotch`, `approvalWaitSeconds` | true, 120 | |
| `desktopChats` | true | watch Claude Desktop / ChatGPT chats via Accessibility |
| `hotkeyOpen`, `hotkeyJump` | ctrl+option+space, ctrl+option+j | `""` turns one off |
| `followCursorAcrossDisplays` | false | move the pet to whichever display the cursor is on |
| `menuBarIcon` | false | the old menu bar fallback |

## How it works

- `hooks/notch-hook.sh`: forwards events (async, 0.5s timeout, always exits 0). `--codex` tags Codex.
- `hooks/notch-permission.sh`: PermissionRequest hook; holds the request open until you answer in the notch.
- Hooks ignore NotchPet's own `claude -p` calls via `NOTCHPET_INTERNAL=1`.
- Older sessions are found in `~/.claude/projects/*/*.jsonl` (last 14 days). That format is internal to
  Claude Code, so the reader is best-effort.
- `NOTCHPET_HOME` / `NOTCHPET_SOCKET` override the data folder and socket (handy for tests; socket path < 104 bytes).
- Ad-hoc signing means macOS may forget the Accessibility grant after a rebuild; toggle it off/on in
  System Settings → Privacy & Security → Accessibility.

## Source map

`Pet` (3D creature) · `AppDelegate` (wiring, hotkeys, summaries) · `SessionStore` (state machine, approvals, links, stats) ·
`SocketServer` · `NotchController` (panel, hover, scroll, escalation) · `NotchView` (all UI) ·
`Projects` (the two cards) · `DesktopChatWatcher` · `WindowIndex` · `TerminalJumper` · `Summarizer` (claude -p, transcript reader, indexer) ·
`PushNotifier` · `HotKey` · `Config` · `StatusController` (menu bar fallback)
