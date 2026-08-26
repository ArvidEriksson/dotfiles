#!/usr/bin/env bash
# Dispatch a coding task to a Claude agent running in its own Herdr worktree.
#
#   herdr-dispatch <branch> <repo-path> <brief-file> \
#       [--name NAME] [--base REF] [--model MODEL] [--allowed-paths P[,P...]] [--no-jitter]
#
# Provisions (or reuses) the worktree for <branch>, drops <brief-file> in it as
# .agent-brief.md, starts a Claude agent in that worktree's pane, and points the
# agent at the brief. Returns immediately with JSON describing the dispatch --
# it does not wait. Use herdr-collect to wait for and inspect the result.
#
# The agent's pane is cwd'd into the worktree, so it satisfies the worktree
# guard natively. Focus stays wherever it was.
#
# --base REF
#   Fork the new branch from REF instead of whatever the primary checkout
#   happens to point at. Always pass this: without it a stale primary silently
#   becomes the base of every branch, and every later review diff carries noise
#   that is not the coder's. Ignored when the branch already exists.
#
# --model MODEL
#   Launch the coder as `claude --model MODEL` (e.g. sonnet). The model is argv on
#   the claude process, so it can only be set at launch: passing this makes the
#   dispatch refuse to reuse the Claude that Herdr's workspace mirroring may have
#   already started, and start its own -- splitting a pane if the mirrored agent
#   holds the only one. Without it, behaviour is unchanged: reuse when possible,
#   whatever model `claude` defaults to.
#
# --allowed-paths
#   Comma-separated path prefixes this branch is allowed to touch. Recorded, not
#   enforced at write time; herdr-collect asserts the final diff stayed inside
#   them, which catches out-of-lane edits without reading a diff.
#
# Both land in .agent-dispatch.json alongside the resolved base SHA. That pin is
# what herdr-collect measures against, so a base that moves mid-run cannot
# distort the diff.
#
# Dispatches are staggered by a short random delay. Linked worktrees have
# independent indexes but share the parent .git, so simultaneous starts collide
# on ref and index locks. Suppress with --no-jitter or HERDR_DISPATCH_NO_JITTER=1.
set -euo pipefail

herdr="${HERDR_BIN:-$HOME/.local/bin/herdr}"
worktree_cmd="${HERDR_WORKTREE_BIN:-$HOME/.local/bin/herdr-worktree}"

usage="usage: $(basename "$0") <branch> <repo-path> <brief-file> [--name NAME] [--base REF] [--model MODEL] [--allowed-paths P[,P...]] [--no-jitter]"

branch=""; repo_arg=""; brief=""; name=""; base_ref=""; model=""; allowed_paths=""
jitter=1
[ "${HERDR_DISPATCH_NO_JITTER:-}" = "1" ] && jitter=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="${2:-}"; shift 2 ;;
    --base) base_ref="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --allowed-paths) allowed_paths="${2:-}"; shift 2 ;;
    --no-jitter) jitter=0; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *)
      if   [ -z "$branch" ];   then branch="$1"
      elif [ -z "$repo_arg" ]; then repo_arg="$1"
      elif [ -z "$brief" ];    then brief="$1"
      else echo "unexpected argument: $1" >&2; exit 64
      fi
      shift ;;
  esac
done

if [ -z "$branch" ] || [ -z "$repo_arg" ] || [ -z "$brief" ]; then
  echo "$usage" >&2
  exit 64
fi
[ -r "$brief" ] || { echo "brief not readable: $brief" >&2; exit 1; }

common="$(git -C "$repo_arg" rev-parse --git-common-dir 2>/dev/null)" || {
  echo "not a git repository: $repo_arg" >&2; exit 1; }
case "$common" in
  /*) ;;
  *) common="$(cd "$repo_arg" && cd "$(dirname "$common")" && pwd)/$(basename "$common")" ;;
esac
repo="$(cd "$(dirname "$common")" && pwd)"

existing="$(git -C "$repo" worktree list --porcelain | awk -v b="refs/heads/$branch" '
  /^worktree /{p=$2}
  /^branch /{ if ($2 == b) { print p; exit } }')"

# Resolve the base before touching git, so the recorded SHA is the one the
# branch actually forks from. With no --base this is the primary checkout's
# current HEAD -- the historical behaviour, now at least written down.
if [ -n "$base_ref" ]; then
  base_sha="$(git -C "$repo" rev-parse --verify --quiet "$base_ref^{commit}" || true)"
  [ -n "$base_sha" ] || { echo "--base is not a resolvable commit in $repo: $base_ref" >&2; exit 1; }
else
  base_ref="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  base_sha="$(git -C "$repo" rev-parse --verify --quiet HEAD || true)"
fi

# Stagger concurrent dispatches: every linked worktree shares the parent .git,
# so simultaneous ref writes collide on locks that are only held for
# milliseconds. A short random delay is enough to decorrelate them.
if [ "$jitter" -eq 1 ]; then
  sleep "$(awk -v s="$$" 'BEGIN{srand(s); printf "%.3f", 0.1 + rand()*0.4}')"
fi

if [ -n "$existing" ]; then
  json="$("$herdr" worktree open --cwd "$repo" --path "$existing" --no-focus 2>&1)" || true
  wt="$existing"
  # An existing branch already has a base. Trust the pin recorded at its first
  # dispatch; only fall back to a merge-base when there is no record.
  if prior="$(jq -r '.base_sha // empty' "$existing/.agent-dispatch.json" 2>/dev/null)" && [ -n "$prior" ]; then
    base_sha="$prior"
    base_ref="$(jq -r '.base // empty' "$existing/.agent-dispatch.json" 2>/dev/null)"
  else
    base_sha="$(git -C "$existing" merge-base "$base_sha" HEAD 2>/dev/null || printf '%s' "$base_sha")"
  fi
else
  # Only pin when we actually resolved a commit. An unborn or detached HEAD with no
  # --base leaves base_sha empty, and passing --base "" would fail the create
  # outright rather than falling back to the old implicit behaviour.
  if [ -n "$base_sha" ]; then
    json="$("$herdr" worktree create --cwd "$repo" --branch "$branch" --base "$base_sha" --no-focus 2>&1)" || true
  else
    json="$("$herdr" worktree create --cwd "$repo" --branch "$branch" --no-focus 2>&1)" || true
  fi
  wt="$(printf '%s' "$json" | jq -r '.result.worktree.path // empty' 2>/dev/null)"
fi
if [ -z "$wt" ] || [ ! -d "$wt" ]; then
  echo "could not provision a worktree for $branch:" >&2
  printf '%s\n' "$json" >&2
  exit 1
fi

workspace="$(printf '%s' "$json" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)"
if [ -z "$workspace" ]; then
  workspace="$("$herdr" worktree list --cwd "$repo" 2>/dev/null \
    | jq -r --arg p "$wt" '.result.worktrees[]? | select(.path == $p) | .open_workspace_id // empty' | head -1)"
fi
[ -n "$workspace" ] || { echo "could not resolve a workspace for $wt" >&2; printf '%s\n' "$json" >&2; exit 1; }

cp "$brief" "$wt/.agent-brief.md"

# The dispatch record. herdr-collect reads base_sha from here rather than
# guessing a base, and asserts the diff stayed inside allowed_paths.
jq -n \
  --arg branch "$branch" --arg base "$base_ref" --arg base_sha "$base_sha" \
  --arg repo "$repo" --arg paths "$allowed_paths" --arg model "$model" \
  '{branch:$branch, base:$base, base_sha:$base_sha, repo:$repo, model:$model,
    allowed_paths: ($paths | if . == "" then [] else split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != "")) end)}' \
  > "$wt/.agent-dispatch.json"

# Keep both out of the coder's commits. info/exclude is shared by every
# worktree of this repo, which is what we want.
exclude="$(git -C "$repo" rev-parse --git-common-dir)/info/exclude"
case "$exclude" in /*) ;; *) exclude="$repo/$exclude" ;; esac
mkdir -p "$(dirname "$exclude")"
for f in .agent-brief.md .agent-dispatch.json; do
  grep -qxF "$f" "$exclude" 2>/dev/null || echo "$f" >> "$exclude"
done

# Herdr brings a worktree workspace up mirroring the source workspace's layout,
# which usually means a Claude agent is already running in it. Prefer that one.
# Pane ids from the create response go stale as the layout settles, so always
# re-query rather than trusting them.
find_ready_agent() {
  "$herdr" agent list 2>/dev/null | jq -r --arg ws "$workspace" '
    .result.agents[]?
    | select(.workspace_id == $ws and .agent == "claude" and .interactive_ready == true)
    | .name // empty' | head -1
}

first_pane() {
  "$herdr" pane list --workspace "$workspace" 2>/dev/null \
    | jq -r '.result.panes[0].pane_id // empty'
}

free_pane_in_workspace() {
  "$herdr" pane list --workspace "$workspace" 2>/dev/null \
    | jq -r '.result.panes[]? | select(.agent == null) | .pane_id' | head -1
}

# The model is fixed at launch: it is argv on the claude process, so it can only
# be set on an agent we start ourselves. There is no way to re-flag a running one.
model_args=()
[ -n "$model" ] && model_args=(-- --model "$model")

start_agent_in() {
  local target="$1" candidate out
  candidate="${name:-claude-${target//:/-}}"
  candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  out="$("$herdr" agent start "$candidate" --kind claude --pane "$target" \
    ${model_args[@]+"${model_args[@]}"} 2>&1)" || return 1
  case "$out" in
    *'"error"'*) return 1 ;;
  esac
  name="$candidate"
  pane="$target"
}

pane=""
for i in $(seq 1 60); do
  # Reusing the mirrored agent is the cheapest path, but it was launched without
  # our model flag -- so with --model it is the wrong agent, however ready it is.
  if [ -z "$model" ]; then
    found="$(find_ready_agent)"
    if [ -n "$found" ]; then
      name="$found"
      pane="$("$herdr" agent get "$name" 2>/dev/null | jq -r '.result.agent.pane_id // empty')"
      break
    fi
  fi

  free_pane="$(free_pane_in_workspace)"
  if [ -n "$free_pane" ]; then
    if start_agent_in "$free_pane"; then break; fi
  elif [ -n "$model" ] && [ "$i" -ge 6 ]; then
    # Every pane is held by an agent we did not start, and waiting will not free
    # one. Split a pane we own instead of displacing the incumbent, which may be
    # the user's own session.
    anchor="$(first_pane)"
    if [ -n "$anchor" ]; then
      split_pane="$("$herdr" pane split "$anchor" --direction down --cwd "$wt" --no-focus 2>/dev/null \
        | jq -r '.result.pane.pane_id // empty')"
      if [ -n "$split_pane" ]; then
        sleep 1
        if start_agent_in "$split_pane"; then break; fi
      fi
    fi
  fi
  sleep 0.5
done

[ -n "${name:-}" ] || { echo "no Claude agent became ready in workspace $workspace" >&2; exit 1; }

scope_line=""
if [ -n "$allowed_paths" ]; then
  scope_line="

Confine your changes to these paths: $allowed_paths. Another coder owns everything else in this repo right now. If the brief cannot be finished without editing outside them, stop and say which path you need and why."
fi

read -r -d '' prompt <<EOF || true
Your task brief is in .agent-brief.md in this directory. Read it first, then carry it out end to end.

You are already inside the Herdr worktree for branch $branch, forked from $base_ref at $base_sha. Do not create another worktree and do not change directory out of this one.

When the work is done: commit on this branch. Do NOT push and do NOT open a pull request.

Other coders are committing in sibling worktrees of this same repository, which share one .git directory. If a git command fails with "Unable to create '.git/index.lock': File exists" or any other lock error, that is contention, not a broken repo: wait and retry the same command up to 5 times, backing off 200ms, 400ms, 800ms, 1.6s, 3.2s. Never delete a lock file by hand, and never abandon uncommitted work because of one.$scope_line

If the brief is genuinely ambiguous, say so and stop rather than guessing.
EOF

"$herdr" agent prompt "$name" "$prompt" >/dev/null

jq -n \
  --arg agent "$name" --arg branch "$branch" --arg worktree "$wt" \
  --arg repo "$repo" --arg pane "$pane" --arg workspace "$workspace" \
  --arg base "$base_ref" --arg base_sha "$base_sha" --arg model "$model" \
  '{agent:$agent, branch:$branch, worktree:$worktree, repo:$repo, pane:$pane,
    workspace:$workspace, base:$base, base_sha:$base_sha, model:$model}'
