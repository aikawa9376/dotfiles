#!/bin/bash

terminal_title="Alacritty"

current_window_id=$(xdotool getwindowfocus)
terminal_window_id=$(xdotool search --name --onlyvisible "$terminal_title")

if test $current_window_id -eq $browser_window_id
then
  xdotool key "ctrl+w"
else
  xdotool key "ctrl+w"
fi
