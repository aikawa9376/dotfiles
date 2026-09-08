#!/bin/sh
set -eu
config_dir="$HOME/.config/waybar"
sh "$config_dir/modules/build-calendar.sh"
exec waybar -c "$config_dir/hyprland.jsonc" -s "$config_dir/style.css"
