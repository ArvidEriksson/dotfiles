#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.cache/.transparency_state"
OVERRIDE_FILE="$HOME/.config/hypr/UserConfigs/OpacityOverride.conf"
KITTY_OVERRIDE="$HOME/.config/kitty/opacity-override.conf"

OPAQUE_RULES='# Managed by ToggleTransparency.sh — do not edit manually
decoration {
  active_opacity = 1.0
  inactive_opacity = 1.0
}
windowrule = match:tag browser, opacity 1.0 1.0
windowrule = match:tag projects, opacity 1.0 1.0
windowrule = match:tag im, opacity 1.0 1.0
windowrule = match:tag multimedia, opacity 1.0 1.0
windowrule = match:tag file-manager, opacity 1.0 1.0
windowrule = match:tag terminal, opacity 1.0 1.0
windowrule = match:class ^(gedit|org.gnome.TextEditor|mousepad)$, opacity 1.0 1.0
windowrule = match:class ^(deluge)$, opacity 1.0 1.0
windowrule = match:class ^(seahorse)$, opacity 1.0 1.0
windowrule = match:class ^(Spotify|spotify)$, opacity 1.0 1.0
windowrule = match:class ^(Slack|slack)$, opacity 1.0 1.0
'

TRANSPARENT_RULES='# Managed by ToggleTransparency.sh — do not edit manually
'

ensure_state() {
  [[ -f "$STATE_FILE" ]] || echo "transparent" > "$STATE_FILE"
}

cmd_toggle() {
  ensure_state
  state="$(cat "$STATE_FILE")"

  if [[ "$state" == "transparent" ]]; then
    printf '%s' "$OPAQUE_RULES" > "$OVERRIDE_FILE"
    echo "background_opacity 1.0" > "$KITTY_OVERRIDE"
    echo "opaque" > "$STATE_FILE"
    hyprctl reload >/dev/null 2>&1
    for sock in /tmp/kitty-sock-*; do
      kitty @ --to unix:"$sock" set-background-opacity 1.0 2>/dev/null || true
    done
    notify-send -u low "Transparency: Off" "All windows are now opaque" || true
  else
    printf '%s' "$TRANSPARENT_RULES" > "$OVERRIDE_FILE"
    rm -f "$KITTY_OVERRIDE"
    echo "transparent" > "$STATE_FILE"
    hyprctl reload >/dev/null 2>&1
    for sock in /tmp/kitty-sock-*; do
      kitty @ --to unix:"$sock" set-background-opacity 0.95 2>/dev/null || true
    done
    notify-send -u low "Transparency: On" "Window transparency restored" || true
  fi
  pkill -RTMIN+3 waybar || true
}

cmd_status() {
  ensure_state
  state="$(cat "$STATE_FILE")"

  if [[ "$state" == "opaque" ]]; then
    printf '{"text":"󰈈","class":"opaque","tooltip":"Transparency off (click to enable)"}\n'
  else
    printf '{"text":"󰂵","class":"transparent","tooltip":"Transparency on (click to disable)"}\n'
  fi
}

case "${1:-}" in
  toggle) cmd_toggle ;;
  status) cmd_status ;;
  *) echo "usage: $0 [toggle|status]" >&2; exit 2 ;;
esac
