#!/usr/bin/env bash
# Create (or reopen) a Herdr worktree for a branch.
#
#   herdr-worktree <branch> [repo-path]              interactive: also opens a
#                                                     focused tab running Claude
#   herdr-worktree --path-only <branch> [repo-path]  agent use: no focus, no
#                                                     agent, prints only the path
#
# --path-only is what an agent calls to provision its own workspace. It stays in
# whatever directory it was launched in and addresses the worktree by absolute
# path, so no pane, focus change, or second session is involved.
#
# repo-path defaults to the primary checkout of whatever repo you are standing
# in, so running this from inside a worktree still branches off the main
# checkout rather than nesting.
set -euo pipefail

herdr="${HERDR_BIN:-$HOME/.local/bin/herdr}"

path_only=0
if [ "${1:-}" = "--path-only" ]; then
  path_only=1
  shift
fi

branch="${1:-}"
if [ -z "$branch" ]; then
  echo "usage: $(basename "$0") [--path-only] <branch> [repo-path]" >&2
  exit 64
fi
repo_arg="${2:-$PWD}"

# Resolve to the PRIMARY checkout: in a linked worktree, --git-common-dir points
# back at the main .git, whose parent is the main checkout.
common="$(git -C "$repo_arg" rev-parse --git-common-dir 2>/dev/null)" || {
  echo "not a git repository: $repo_arg" >&2
  exit 1
}
case "$common" in
  /*) ;;
  *) common="$(cd "$repo_arg" && cd "$(dirname "$common")" && pwd)/$(basename "$common")" ;;
esac
repo="$(cd "$(dirname "$common")" && pwd)"

# Reuse an existing checkout of this branch rather than failing on it.
existing="$(git -C "$repo" worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2}
  /^branch /{ if ($2 == b) { print p; exit } }')"

if [ -n "$existing" ]; then
  json=""
  path="$existing"
else
  focus_flag="--focus"
  [ "$path_only" -eq 1 ] && focus_flag="--no-focus"
  json="$("$herdr" worktree create --cwd "$repo" --branch "$branch" "$focus_flag" 2>&1)" || true
  path="$(printf '%s' "$json" | jq -r '.result.worktree.path // empty' 2>/dev/null)"
  if [ -z "$path" ]; then
    echo "herdr worktree create failed:" >&2
    printf '%s\n' "$json" >&2
    exit 1
  fi
fi

if [ "$path_only" -eq 1 ]; then
  printf '%s\n' "$path"
  exit 0
fi

pane="$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
if [ -z "$pane" ]; then
  json="$("$herdr" worktree open --cwd "$repo" --branch "$branch" --focus 2>&1)" || true
  pane="$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
fi
if [ -z "$pane" ]; then
  workspace="$(printf '%s' "$json" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)"
  [ -n "$workspace" ] || { echo "could not resolve a pane; worktree is at $path" >&2; exit 1; }
  pane="$("$herdr" pane list --workspace "$workspace" | jq -r '.result.panes[0].pane_id // empty')"
fi
[ -n "$pane" ] || { echo "could not resolve a pane; worktree is at $path" >&2; exit 1; }

echo "worktree: $path"

# Agent names: lowercase, [a-z0-9_-] only, and pane ids are hex-suffixed.
name="claude-${pane//:/-}"
name="${name,,}"

# `agent start` needs the pane already at an interactive prompt; workspace
# creation returns before the shell finishes coming up, so retry briefly.
for _ in $(seq 1 40); do
  if out="$("$herdr" agent start "$name" --kind claude --pane "$pane" 2>&1)"; then
    case "$out" in
      *'"error"'*) ;;
      *) exit 0 ;;
    esac
  fi
  case "$out" in
    *agent_pane_busy*|*'not an available shell'*) sleep 0.25 ;;
    *) echo "$out" >&2; exit 1 ;;
  esac
done

echo "timed out waiting for pane $pane to reach a shell prompt" >&2
exit 1
