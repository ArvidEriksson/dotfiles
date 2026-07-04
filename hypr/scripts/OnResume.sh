#!/usr/bin/env bash
# ==================================================
#  Restore the session after resume from sleep/suspend.
# --------------------------------------------------
#  On wake (closing/opening the laptop lid) the Wayland outputs are torn
#  down and re-added. Two things break:
#    - Waybar exits with its outputs and nothing respawns it.
#    - The wallpaper (swww/awww) goes black until the image is re-applied
#      to the freshly re-added output.
#
#  This listens for logind's PrepareForSleep D-Bus signal and repairs both
#  on the wake edge. We use the D-Bus signal rather than a
#  WantedBy=suspend.target user unit because systemd here exposes no
#  user-level sleep targets.
# ==================================================

SCRIPTSDIR="$HOME/.config/hypr/scripts"

# Single-instance guard: hold an exclusive lock for our lifetime.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/hypr-onresume.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

on_resume() {
    # Let the compositor re-add outputs before clients enumerate them.
    sleep 1

    # Waybar exits with its outputs; relaunch it.
    pkill -x waybar 2>/dev/null
    sleep 1
    waybar >/dev/null 2>&1 &
    disown

    # Re-apply the wallpaper (idempotent: re-issues swww/awww img).
    "$SCRIPTSDIR/WallpaperDaemon.sh" >/dev/null 2>&1 &
    disown
}

# PrepareForSleep(true)  -> about to sleep
# PrepareForSleep(false) -> just woke up   <-- repair here
gdbus monitor --system \
    --dest org.freedesktop.login1 \
    --object-path /org/freedesktop/login1 2>/dev/null |
while read -r line; do
    case "$line" in
        *PrepareForSleep*false*) on_resume ;;
    esac
done
