#!/usr/bin/env bash
# ==================================================
#  Keep new windows of an app on the workspace where that app already lives,
#  instead of on whatever workspace happens to be focused when they map.
#
#  Hyprland has no "open next to the parent window" window rule, so this
#  subscribes to the IPC event stream and moves matching windows silently
#  (the window moves; your view does not).
#
#  Mainly for the Unity editor, which pops progress bars, build settings,
#  package manager, preferences etc. as separate top-level windows.
# ==================================================

# Classes that should follow their own kind. Anchoring is per exact class,
# so "Unity" windows follow Unity and "unityhub" follows Unity Hub.
FOLLOW_CLASS_REGEX='^([Uu]nity.*)$'

SOCKET2="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

[[ -S "$SOCKET2" ]] || {
	echo "Error: Hyprland socket2 not found at $SOCKET2" >&2
	exit 1
}

# One listener per session, even if this gets launched again by hand.
exec 9>"$XDG_RUNTIME_DIR/AppWindowFollow.lock"
flock -n 9 || exit 0

follow() {
	local addr="0x$1" class="$2" anchor current

	# The biggest existing window of that class is the app's main window.
	# Special workspaces (scratchpad) are never an anchor.
	anchor=$(hyprctl clients -j | jq -r --arg c "$class" --arg a "$addr" '
		[ .[] | select(.class == $c and .address != $a and .workspace.id > 0) ]
		| max_by(.size[0] * .size[1]) // empty | .workspace.id')
	[[ -n "$anchor" ]] || return

	current=$(hyprctl clients -j | jq -r --arg a "$addr" '
		.[] | select(.address == $a) | .workspace.id')
	[[ -n "$current" && "$current" != "$anchor" ]] || return

	hyprctl dispatch movetoworkspacesilent "$anchor,address:$addr" >/dev/null
}

socat -u UNIX-CONNECT:"$SOCKET2" - | while read -r line; do
	case "$line" in
		openwindow\>\>*) ;;
		*) continue ;;
	esac

	# openwindow>>ADDRESS,WORKSPACENAME,CLASS,TITLE - title may contain commas
	IFS=',' read -r addr ws class title <<<"${line#openwindow>>}"
	if [[ "$class" =~ $FOLLOW_CLASS_REGEX ]]; then
		follow "$addr" "$class"
	fi
done
