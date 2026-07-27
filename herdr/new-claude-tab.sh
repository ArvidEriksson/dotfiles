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

exec "$herdr" pane run "$pane" claude
