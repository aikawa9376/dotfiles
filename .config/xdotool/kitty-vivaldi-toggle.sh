#!/bin/bash

browser_title="vivaldi-stable"
terminal_title="kitty"

current_window_id=$(xdotool getwindowfocus)
browser_window_id=$(xdotool search --class --onlyvisible "$browser_title" | sort)
terminal_window_id=$(xdotool search --class --onlyvisible "$terminal_title")

if [ -z "$terminal_window_id" ]; then
  kitty
  exit
fi

if [ -z "$browser_window_id" ]; then
  vivaldi-stable
  exit
fi

if test $current_window_id -eq $terminal_window_id
then
  xdotool windowactivate $browser_window_id
else
  xdotool windowactivate $terminal_window_id
fi
