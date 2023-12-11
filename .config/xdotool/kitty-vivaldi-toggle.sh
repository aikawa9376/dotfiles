#!/bin/bash

browser_title="vivaldi-stable"
terminal_title="kitty"

current_window_id=$(xdotool getwindowfocus)
browser_window_id=$(xdotool search --class --onlyvisible "$browser_title")
terminal_window_id=$(xdotool search --class --onlyvisible "$terminal_title")

if test $current_window_id -eq $browser_window_id
then
  xdotool windowactivate $terminal_window_id
else
  xdotool windowactivate $browser_window_id
fi
