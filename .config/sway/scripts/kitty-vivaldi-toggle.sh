#!/bin/sh
set -eu

tree=$(swaymsg -t get_tree -r)
focused_app=$(
    printf '%s\n' "$tree" |
        jq -r '.. | objects | select(.focused? == true) | .app_id // .window_properties.class // empty' |
        tail -n 1
)

case "$focused_app" in
    kitty)
        target='vivaldi-stable'
        command='vivaldi-stable'
        ;;
    *)
        target='kitty'
        command='kitty'
        ;;
esac

if printf '%s\n' "$tree" |
        jq -e --arg target "$target" \
            '.. | objects | select((.app_id // .window_properties.class // "") == $target)' \
            >/dev/null; then
    swaymsg "[app_id=\"$target\"] focus" >/dev/null
else
    "$command" >/dev/null 2>&1 &
fi
