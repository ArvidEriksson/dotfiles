#!/bin/sh
LOCK="$HOME/.config/BraveSoftware/Brave-Browser/SingletonLock"
if [ -L "$LOCK" ]; then
    PID=$(readlink "$LOCK" | grep -o '[0-9]*')
    kill -0 "$PID" 2>/dev/null || rm "$LOCK"
fi
