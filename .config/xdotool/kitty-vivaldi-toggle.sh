#!/bin/bash

browser_title="vivaldi-stable"
terminal_title="kitty"

current_window_id=$(xdotool getwindowfocus)
browser_window_id=$(xdotool search --class --onlyvisible "$browser_title")
terminal_window_id=$(xdotool search --class --onlyvisible "$terminal_title")

if [ -z "$terminal_window_id" ]; then
  kitty
fi

if [ -z "$browser_window_id" ]; then
  vivaldi-stable
fi

if test $current_window_id -eq $browser_window_id
then
  xdotool windowactivate $terminal_window_id
else
  xdotool windowactivate $browser_window_id
fi
