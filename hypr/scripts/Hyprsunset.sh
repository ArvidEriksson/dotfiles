#!/usr/bin/env bash
# ==================================================
#  KoolDots (2026)
#  Project URL: https://github.com/LinuxBeginnings
#  License: GNU GPLv3
#  SPDX-License-Identifier: GPL-3.0-or-later
# ==================================================
set -euo pipefail

# Hyprsunset toggle + Waybar status helper
# Phase 1: manual toggle only (no scheduling)
# Icons:
# - Off: bright sun
# - On: sunset icon if available, otherwise a blue sun
#
# Customize via env vars:
#   HYPRSUNSET_TEMP   default 4500 (K)
#   HYPRSUNSET_ICON_MODE  sunset|blue  (default: sunset)

STATE_FILE="$HOME/.cache/.hyprsunset_state"
TARGET_TEMP="${HYPRSUNSET_TEMP:-4500}"
ICON_MODE="${HYPRSUNSET_ICON_MODE:-sunset}"

ensure_state() {
  [[ -f "$STATE_FILE" ]] || echo "off" > "$STATE_FILE"
}

# Render icons using pango markup to allow colorization
icon_off() {
  printf "󰖙"
}

icon_on() {
  printf "󰖔"
}

cmd_toggle() {
  ensure_state
  state="$(cat "$STATE_FILE" || echo off)"

  if [[ "$state" == "on" ]]; then
    echo off > "$STATE_FILE"
    pkill -RTMIN+2 waybar || true
    notify-send -u low "Hyprsunset: Disabled" || true
    # Smoothly ramp back to neutral in background
    {
      local steps=20
      local step_delay=0.04
      local neutral=6500
      local current=$TARGET_TEMP
      local increment=$(( (neutral - current) / steps ))
      for ((i = 1; i <= steps; i++)); do
        current=$(( current + increment ))
        hyprctl hyprsunset temperature "$current" >/dev/null 2>&1
        sleep "$step_delay"
      done
      hyprctl hyprsunset identity >/dev/null 2>&1
      pkill -x hyprsunset || true
    } &
    disown
  else
    if command -v hyprsunset >/dev/null 2>&1; then
      pkill -x hyprsunset 2>/dev/null || true; sleep 0.2
      setsid nohup hyprsunset -t "$TARGET_TEMP" >/dev/null 2>&1 &
      disown
    fi
    echo on > "$STATE_FILE"
    pkill -RTMIN+2 waybar || true
    notify-send -u low "Hyprsunset: Enabled" "${TARGET_TEMP}K" || true
  fi
}

cmd_status() {
  ensure_state
  # Prefer live process detection; fall back to state file
  onoff="$(cat "$STATE_FILE" || echo off)"

  if [[ "$onoff" == "on" ]]; then
    txt="$(icon_on)"
    cls="on"
    tip="Night light on @ ${TARGET_TEMP}K"
  else
    txt="$(icon_off)"
    cls="off"
    tip="Night light off"
  fi
  printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$txt" "$cls" "$tip"
}

cmd_init() {
  ensure_state
  state="$(cat "$STATE_FILE" || echo off)"

  if [[ "$state" == "on" ]]; then
    if command -v hyprsunset >/dev/null 2>&1; then
      nohup hyprsunset -t "$TARGET_TEMP" >/dev/null 2>&1 &
    fi
  fi
}

case "${1:-}" in
  toggle) cmd_toggle ;;
  status) cmd_status ;;
  init) cmd_init ;;
  *) echo "usage: $0 [toggle|status|init]" >&2; exit 2 ;;
 esac
