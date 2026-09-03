#!/bin/sh
set -eu

if ! command -v tmux >/dev/null 2>&1 ||
        ! tmux list-sessions >/dev/null 2>&1; then
    exit 0
fi

variables='WAYLAND_DISPLAY DISPLAY SWAYSOCK I3SOCK DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE GTK_IM_MODULE QT_IM_MODULE XMODIFIERS GLFW_IM_MODULE GDK_BACKEND QT_QPA_PLATFORM MOZ_ENABLE_WAYLAND XAUTHORITY'
sessions=$(tmux list-sessions -F '#{session_name}')

for name in $variables; do
    if value=$(printenv "$name"); then
        tmux set-environment -g "$name" "$value"
        printf '%s\n' "$sessions" | while IFS= read -r session; do
            [ -n "$session" ] && tmux set-environment -t "$session" "$name" "$value"
        done
    else
        tmux set-environment -gu "$name" 2>/dev/null || true
        printf '%s\n' "$sessions" | while IFS= read -r session; do
            [ -n "$session" ] && tmux set-environment -t "$session" -u "$name" 2>/dev/null || true
        done
    fi
done
