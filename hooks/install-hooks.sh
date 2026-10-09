#!/bin/bash
# Installs (or with --uninstall removes) the Lantern hook in ~/.claude/settings.json.
# Existing hooks are left untouched. The original is backed up once as settings.json.bak-lantern.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.claude/hooks/lantern-status.sh"
settings="$HOME/.claude/settings.json"
events='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop"]'

command -v jq >/dev/null || { echo "jq not found (ships as /usr/bin/jq on macOS 15+)"; exit 1; }

mkdir -p "$HOME/.claude/hooks"
[ -f "$settings" ] || echo '{}' > "$settings"
[ -f "$settings.bak-lantern" ] || cp "$settings" "$settings.bak-lantern"

if [ "${1:-}" = "--uninstall" ]; then
  add=false
  rm -f "$dest"
else
  add=true
  cp "$here/lantern-status.sh" "$dest"
  chmod +x "$dest"
fi

jq --arg cmd "$dest" --argjson events "$events" --argjson add "$add" '
  def strip:
    map(.hooks |= map(select((.command // "") | contains("lantern-status.sh") | not)))
    | map(select(.hooks | length > 0));
  .hooks = (.hooks // {})
  | reduce $events[] as $ev (.;
      .hooks[$ev] = (((.hooks[$ev] // []) | strip)
        + (if $add then [{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5}]}] else [] end))
      | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end)
' "$settings" > "$settings.tmp"
mv "$settings.tmp" "$settings"

if $add; then
  echo "Hooks installed. Restart your Claude Code sessions so they pick them up."
else
  rm -rf "$HOME/.claude/lantern"
  echo "Hooks removed."
fi
