#!/usr/bin/env bash
# Wait for a dispatched coding agent and report what it produced.
#
#   herdr-collect <agent> [--timeout-ms MS] [--tail N] [--no-wait]
#
# Waits until the agent is idle, done, or blocked, then reports its status
# alongside the git state of the worktree it is working in. Emits JSON.
#
# status "blocked" means Herdr detected an approval or question prompt: the
# agent is waiting on a human, not finished. Treat it as needing attention.
set -euo pipefail

herdr="${HERDR_BIN:-$HOME/.local/bin/herdr}"

agent=""; timeout_ms=1800000; tail_lines=40; wait=1
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout-ms) timeout_ms="${2:-}"; shift 2 ;;
    --tail) tail_lines="${2:-}"; shift 2 ;;
    --no-wait) wait=0; shift ;;
    -h|--help) echo "usage: $(basename "$0") <agent> [--timeout-ms MS] [--tail N] [--no-wait]"; exit 0 ;;
    *) [ -z "$agent" ] && agent="$1" || { echo "unexpected argument: $1" >&2; exit 64; }; shift ;;
  esac
done
[ -n "$agent" ] || { echo "usage: $(basename "$0") <agent> [--timeout-ms MS] [--tail N] [--no-wait]" >&2; exit 64; }

if [ "$wait" -eq 1 ]; then
  "$herdr" agent wait "$agent" --until idle --until done --until blocked \
    --timeout "$timeout_ms" >/dev/null 2>&1 || true
fi

info="$("$herdr" agent get "$agent" 2>&1)" || { echo "no such agent: $agent" >&2; exit 1; }
status="$(printf '%s' "$info" | jq -r '.result.agent.agent_status // .result.agent_status // "unknown"')"
wt="$(printf '%s' "$info" | jq -r '.result.agent.cwd // .result.agent.foreground_cwd // .result.cwd // empty')"

tail_text="$("$herdr" agent read "$agent" --source recent --lines "$tail_lines" --format text 2>/dev/null \
  | jq -r '.result.text // .result.content // empty' 2>/dev/null || true)"

branch=""; base=""; base_sha=""; base_source=""; ahead=0; dirty=""; diffstat=""; commits=""
out_of_scope=""; allowed_paths="[]"
if [ -n "$wt" ] && [ -d "$wt" ]; then
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

  # Prefer the base pinned at dispatch. Measuring against a moving base ref
  # makes the diff drift as other branches land, which reads as the coder's
  # work when it is not.
  if [ -r "$wt/.agent-dispatch.json" ]; then
    base_sha="$(jq -r '.base_sha // empty' "$wt/.agent-dispatch.json" 2>/dev/null || true)"
    base="$(jq -r '.base // empty' "$wt/.agent-dispatch.json" 2>/dev/null || true)"
    allowed_paths="$(jq -c '.allowed_paths // []' "$wt/.agent-dispatch.json" 2>/dev/null || echo '[]')"
  fi
  if [ -n "$base_sha" ] && git -C "$wt" rev-parse --verify --quiet "$base_sha^{commit}" >/dev/null 2>&1; then
    base_source="pinned"
  else
    base_sha=""
    base="$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    [ -n "$base" ] || base="$(git -C "$wt" rev-parse --verify --quiet main >/dev/null 2>&1 && echo main || echo master)"
    base_sha="$base"
    base_source="inferred"
  fi

  ahead="$(git -C "$wt" rev-list --count "$base_sha..HEAD" 2>/dev/null || echo 0)"
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -30)"
  diffstat="$(git -C "$wt" diff --stat "$base_sha"...HEAD 2>/dev/null | tail -25)"
  commits="$(git -C "$wt" log --oneline "$base_sha..HEAD" 2>/dev/null | head -25)"

  # Scope gate: every changed path must sit under one declared prefix. Committed
  # and uncommitted alike -- a coder that strayed and did not commit still strayed.
  if [ "$allowed_paths" != "[]" ]; then
    changed="$( { git -C "$wt" diff --name-only "$base_sha"...HEAD 2>/dev/null
                  git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//' ; } | sort -u)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in .agent-brief.md|.agent-dispatch.json) continue ;; esac
      ok=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        p="${p%/}"
        case "$f" in "$p"|"$p"/*) ok=1; break ;; esac
      done <<< "$(printf '%s' "$allowed_paths" | jq -r '.[]')"
      [ "$ok" -eq 1 ] || out_of_scope="${out_of_scope}${f}"$'\n'
    done <<< "$changed"
    out_of_scope="${out_of_scope%$'\n'}"
  fi
fi

jq -n \
  --arg agent "$agent" --arg status "$status" --arg worktree "$wt" \
  --arg branch "$branch" --arg base "$base" --arg base_sha "$base_sha" \
  --arg base_source "$base_source" --argjson ahead "${ahead:-0}" \
  --arg dirty "$dirty" --arg diffstat "$diffstat" --arg commits "$commits" \
  --argjson allowed_paths "$allowed_paths" --arg out_of_scope "$out_of_scope" \
  --arg tail "$tail_text" \
  '{agent:$agent, status:$status, worktree:$worktree, branch:$branch, base:$base,
    base_sha:$base_sha, base_source:$base_source,
    commits_ahead:$ahead, commits:$commits, uncommitted:$dirty, diffstat:$diffstat,
    allowed_paths:$allowed_paths,
    out_of_scope: ($out_of_scope | if . == "" then [] else split("\n") end),
    tail:$tail}'
