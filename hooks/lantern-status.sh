#!/bin/bash
# Lantern – writes status per Claude Code session to ~/.claude/lantern/<session_id>.json
# Must never write to stdout (UserPromptSubmit/SessionStart put stdout in Claude's context)
# and always exits 0 so it never blocks Claude.
exec >/dev/null 2>&1

JQ=$(command -v jq || echo /usr/bin/jq)
dir="$HOME/.claude/lantern"
mkdir -p "$dir"

# One jq call (it runs on every tool call): first line "<action> <session_id>", then the status JSON
out=$("$JQ" -r '
  def tool:
    .tool_name + (
      if .tool_input.file_path then " · " + (.tool_input.file_path | split("/") | last)
      elif .tool_input.command then " · " + (.tool_input.command | gsub("\\s+"; " ") | .[0:60])
      elif .tool_input.pattern then " · " + (.tool_input.pattern | .[0:40])
      elif .tool_input.url then " · " + (.tool_input.url | .[0:60])
      else "" end);

  .hook_event_name as $ev
  | (if $ev == "SessionStart" then ["done", "Ready"]
     elif $ev == "UserPromptSubmit" then ["working", "Thinking"]
     elif $ev == "PreToolUse" then
       if .tool_name == "AskUserQuestion" then ["waiting", "Has a question"]
       elif .tool_name == "ExitPlanMode" then ["waiting", "Wants you to approve the plan"]
       else ["working", tool] end
     elif $ev == "PostToolUse" then ["working", tool]
     elif $ev == "Notification" then
       # The idle reminder arrives a while after Stop – it must not turn a finished session red
       if .notification_type == "idle_prompt" or ((.message // "") | test("waiting for your input"; "i")) then null
       else ["waiting", (.message // "Waiting for you"
         | if test("permission to use") then "Wants to use " + capture("permission to use (?<t>.+)").t else . end)]
       end
     elif $ev == "Stop" then ["done", "Done, your turn"]
     else null end) as $s
  | if (.session_id // "") == "" then empty
    elif $ev == "SessionEnd" then "end \(.session_id)"
    elif $s == null then empty
    else "write \(.session_id)",
      ({session_id, state: $s[0], detail: $s[1], cwd: (.cwd // ""), transcript: (.transcript_path // ""),
        event: $ev, ts: now} | tojson)
    end')

{ read -r action sid; IFS= read -r json; } <<<"$out"
[ -z "$sid" ] && exit 0
f="$dir/$sid.json"

case "$action" in
  end)   rm -f "$f" ;;
  write) printf '%s\n' "$json" > "$f.tmp" && mv "$f.tmp" "$f" ;;
esac

exit 0
