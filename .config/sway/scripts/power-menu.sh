#!/bin/sh
set -eu

runtime_dir=${XDG_RUNTIME_DIR:-/tmp}
pid_file="$runtime_dir/waybar-power-menu-${UID:-$(id -u)}.pid"

if [ -r "$pid_file" ]; then
    menu_pid=$(cat "$pid_file")
    case "$menu_pid" in
        ''|*[!0-9]*) menu_pid= ;;
    esac

    if [ -n "$menu_pid" ] \
        && [ -r "/proc/$menu_pid/cmdline" ] \
        && grep -zFq -- 'Waybar power menu' "/proc/$menu_pid/cmdline"; then
        kill "$menu_pid"
        rm -f "$pid_file"
        exit 0
    fi

    rm -f "$pid_file"
fi

choice_file="$runtime_dir/waybar-power-menu-choice-$$"
trap 'rm -f "$pid_file" "$choice_file"' EXIT HUP INT TERM

rofi -no-config \
    -dmenu \
    -i \
    -no-custom \
    -p '' \
    -window-title 'Waybar power menu' \
    -theme "$HOME/.config/rofi/power-menu.rasi" \
    >"$choice_file" <<'EOF' &
󰤄  Suspend
󰜉  Reboot
󰐥  Power off
󰗼  Exit Sway
EOF
menu_pid=$!
printf '%s\n' "$menu_pid" > "$pid_file"

if ! wait "$menu_pid"; then
    exit 0
fi

choice=$(cat "$choice_file")
case "$choice" in
    *Suspend) systemctl suspend ;;
    *Reboot) systemctl reboot ;;
    *'Power off') systemctl poweroff ;;
    *'Exit Sway') swaymsg exit ;;
esac
