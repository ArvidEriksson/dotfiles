#!/usr/bin/env bash
# PreToolUse hook for the Skill tool. Logs every invocation and stamps a
# per-session state file so the statusLine wrapper can display it. The state is
# keyed by session_id so a skill invoked in one session never leaks into
# another session's status line.
set -euo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "Skill" ]] || exit 0

skill=$(printf '%s' "$input" | jq -r '.tool_input.skill // empty')
[[ -n "$skill" ]] || exit 0

session=$(printf '%s' "$input" | jq -r '.session_id // "default"')
# Guard the filename against anything unexpected in session_id.
session=${session//[^A-Za-z0-9._-]/_}

state_dir="$HOME/.claude"
mkdir -p "$state_dir"

ts=$(date +%s)
iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf '%s\t%s\t%s\n' "$iso" "$session" "$skill" >> "$state_dir/skill-usage.log"
jq -nc --arg skill "$skill" --argjson ts "$ts" '{skill:$skill, ts:$ts}' \
  > "$state_dir/active-skill.$session.json"

exit 0
