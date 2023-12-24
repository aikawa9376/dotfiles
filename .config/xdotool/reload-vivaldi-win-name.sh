#!/bin/bash

focused_window_id=$(xdotool getwindowfocus) # remember current window
pids=$(xdotool search --class "vivaldi")
for pid in $pids; do
  name=$(xdotool getwindowname $pid)
  echo $name
  echo $1
  if [[ $name =~ $1 ]]; then
    xdotool windowactivate $pid key 'ctrl+shift+r'  # send keystroke to refresh;
  fi
done
xdotool windowactivate --sync $focused_window_id
