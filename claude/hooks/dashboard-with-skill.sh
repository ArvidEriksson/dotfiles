#!/usr/bin/env bash
# statusLine wrapper. Renders claude-dashboard on a single line. When a Skill
# tool has been invoked within MAX_AGE seconds *in this session*, prepends the
# active skill as an extra dashboard-style segment so it blends into the bar.
set -euo pipefail

DASHBOARD="$(ls -d "$HOME"/.claude/plugins/cache/claude-dashboard/claude-dashboard/*/dist/index.js 2>/dev/null | sort -V | tail -1)"
MAX_AGE=300

stdin_payload=$(cat)

if [[ -z "$DASHBOARD" || ! -f "$DASHBOARD" ]]; then
  printf '[claude-dashboard not found — reinstall plugin or remove this wrapper]'
  exit 0
fi

dashboard_out=$(printf '%s' "$stdin_payload" | node "$DASHBOARD")

# Scope the state to this session so skills from other sessions never show here.
session=$(printf '%s' "$stdin_payload" | jq -r '.session_id // "default"' 2>/dev/null || echo default)
session=${session//[^A-Za-z0-9._-]/_}
STATE="$HOME/.claude/active-skill.$session.json"

# Opportunistically prune stale per-session state files (older than 1 day).
find "$HOME/.claude" -maxdepth 1 -name 'active-skill.*.json' -mtime +0 -delete 2>/dev/null || true

skill=""
age_str=""
if [[ -f "$STATE" ]]; then
  raw_skill=$(jq -r '.skill // empty' "$STATE" 2>/dev/null || echo "")
  if [[ -n "$raw_skill" ]]; then
    ts=$(jq -r '.ts // 0' "$STATE" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - ts))
    if (( age < MAX_AGE )); then
      skill="$raw_skill"
      if   (( age < 60 ));   then age_str="${age}s"
      elif (( age < 3600 )); then age_str="$((age/60))m"
      else                        age_str="$((age/3600))h"
      fi
    fi
  fi
fi

if [[ -n "$skill" ]]; then
  display="$skill"
  if (( ${#display} > 20 )); then
    display="${display##*:}"
    (( ${#display} > 20 )) && display="${display:0:19}…"
  fi

  # Match the dashboard's segment vocabulary: a glyph, a coloured label, a dim
  # detail, and a dim " │ " separator — no inverted background block.
  reset=$'\e[0m'
  fg_magenta=$'\e[35m'
  dim=$'\e[2m'
  segment=$(printf '%s🧠 %s%s %s(%s)%s%s │ %s' \
    "$fg_magenta" "$display" "$reset" "$dim" "$age_str" "$reset" "$dim" "$reset")
  printf '%s%s' "$segment" "$dashboard_out"
else
  printf '%s' "$dashboard_out"
fi
