#!/bin/bash
qdbus org.kde.krunner /App querySingleRunner windows ""
sleep 0.2
xdotool type 'window '
xdotool key "shift+BackSpace"
