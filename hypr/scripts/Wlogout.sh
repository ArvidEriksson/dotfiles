#!/usr/bin/env bash
# ==================================================
#  KoolDots (2026)
#  Project URL: https://github.com/LinuxBeginnings
#  License: GNU GPLv3
#  SPDX-License-Identifier: GPL-3.0-or-later
# ==================================================
# wlogout (Power, Screen Lock, Suspend, etc)

# Check if wlogout is already running
if pgrep -x "wlogout" > /dev/null; then
    pkill -x "wlogout"
    exit 0
fi

BUTTONS=6

# Logical (scaled) size of the focused monitor — wlogout margins are in logical px
read -r width height <<< "$(hyprctl -j monitors | jq -r '.[] | select(.focused==true) | "\(.width / .scale | floor) \(.height / .scale | floor)"')"

if [[ -z "$width" || -z "$height" ]]; then
    echo "Could not detect monitor geometry, using wlogout defaults"
    wlogout --protocol layer-shell -b $BUTTONS &
    exit 0
fi

# Square buttons: cell size capped by both height and total width
size=$(( height / 4 ))
max_by_width=$(( width / (BUTTONS + 2) ))
(( size > max_by_width )) && size=$max_by_width

L_val=$(( (width - size * BUTTONS) / 2 ))
R_val=$L_val
T_val=$(( (height - size) / 2 ))
B_val=$T_val

wlogout --protocol layer-shell -b $BUTTONS -L $L_val -R $R_val -T $T_val -B $B_val &
