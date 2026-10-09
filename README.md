# Lantern

Session status for Claude Code, right above your Dock.

A small macOS app for when you run several Claude Code sessions in parallel. A panel just
above the Dock shows what each session is doing, so you see at a glance when one is waiting
for you.

```
        ┌─────────────────────────────────────────────────────────────┐
        │  ✻ api  84k    ✶ web  212k    ✻ docs  36k  │  ▬▬▬░░ 45% · 215m │
        └─────────────────────────────────────────────────────────────┘
   [ Dock ........................................................... ]
```

- 🔴 **Waiting for you**: a permission, a question or a plan to approve (pulses)
- 🟡 **Working**: the star animates
- 🟢 **Done, your turn**: still

On the right is the 5-hour quota and the minutes until it resets.

## Requirements

- macOS 14 or later
- Xcode or Command Line Tools (`xcode-select --install`)
- `jq` (built in from macOS 15, otherwise `brew install jq`)
- Claude Code (works in the terminal and in the VS Code extension)

## Install

```bash
git clone https://github.com/Wish-You-Were-Here/lantern.git
cd lantern
./install.sh
```

Then restart your Claude Code sessions so they pick up the new hooks.

`install.sh` does two things:

1. Adds a hook to `~/.claude/settings.json`. The original is backed up once as
   `settings.json.bak-lantern`, and existing hooks are left untouched.
2. Builds the app from source, copies it to `/Applications` and launches it.

## Usage

| Action | Result |
|---|---|
| Click a session | Opens the project folder in VS Code |
| Hover a session | Shows what it's doing, how long ago, context usage and tokens |
| Right-click a session | Remove it from the list, or open the remote control session |
| Hover the quota | Shows the 5-hour and weekly quota with time until reset |
| Click the quota | Refreshes the quota now |
| Click the Dock icon | Shows or hides the panel |
| Right-click the Dock icon | Lists all sessions, *Clear Done*, *Open at Login* |

Sessions connected to remote control get a small phone icon.

The number after each session is the tokens the session itself has produced (output plus newly
written input). Cache reads are not counted, since they would inflate the total into the millions.

### Other editor

```bash
defaults write se.wishyouwerehere.lantern editorApp "Cursor"
```

## Uninstall

```bash
./uninstall.sh
```

## How it works

- `hooks/lantern-status.sh` runs on SessionStart, UserPromptSubmit, PreToolUse,
  PostToolUse, Notification, Stop and SessionEnd. It writes one JSON file per session
  to `~/.claude/lantern/`.
- The app watches that folder and reads each session's transcript to count tokens.
- `~/.claude/sessions/` is used to see which sessions are connected to remote control,
  and to clean up sessions whose process is no longer alive.

## Good to know

- **Internal formats.** The app reads files Claude Code writes for its own use: transcripts and
  `~/.claude/sessions/`. They are undocumented and may change when Claude Code updates.
- **The quota.** It is fetched from the same endpoint Claude Code itself uses
  (`api.anthropic.com/api/oauth/usage`), with Claude Code's login from the keychain. It is not
  an official API. If you sign in with an API key instead of a subscription, no quota is shown,
  but the rest of the panel works.
- **Privacy.** Everything stays on your machine. The only network request is the quota fetch,
  made every three minutes.
- **Unofficial.** This project is not affiliated with or endorsed by Anthropic.

## License

MIT
