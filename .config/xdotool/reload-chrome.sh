#!/bin/bash

focused_window_id=$(xdotool getwindowfocus)                             # remember current window
xdotool search --onlyvisible --class "Chrome" windowactivate key 'ctrl+shift+r'  # send keystroke to refresh;
xdotool windowactivate --sync $focused_window_id
