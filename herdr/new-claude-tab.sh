#!/usr/bin/env bash
# prefix+C in Herdr: new tab in the active workspace with Claude Code running.
# Bound via [[keys.command]] in ~/.config/herdr/config.toml.
#
# No workspace/cwd arguments needed: the server places the tab in the active
# workspace and applies the terminal.new_cwd policy (default "follow", i.e. the
# focused pane's directory) on its own.
set -euo pipefail

herdr="${HERDR_BIN:-$HOME/.local/bin/herdr}"

pane="$("$herdr" tab create --focus | jq -r '.result.root_pane.pane_id')"
[ -n "$pane" ] && [ "$pane" != "null" ] || {
  echo "herdr tab create returned no pane id" >&2
  exit 1
}

# `agent start` rather than `pane run`: it registers the pane as a *managed*
# agent, so the session snapshot records managed_agent_kind + launch_argv
# alongside the Claude session id the SessionStart hook reports. That pair is
# what lets [session] resume_agents_on_restore bring the tab back running
# `claude --resume <id>` after a reboot. `pane run` only ever records the cwd,
# so those tabs come back as bare shells.
#
# `agent start` requires the pane to already be sitting at an interactive shell
# prompt, and `tab create` returns before the shell has finished coming up — so
# retry briefly instead of failing the whole binding on that race.
for _ in $(seq 1 40); do
  if out="$("$herdr" agent start "claude-${pane//:/-}" --kind claude --pane "$pane" 2>&1)"; then
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
