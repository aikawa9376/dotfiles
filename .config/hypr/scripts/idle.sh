#!/bin/sh
set -eu

# Only sleep while every configured monitor is present.
exec swayidle -w \
    timeout 600 "hyprctl eval 'require(\"feature.idle\").sleep()'" \
    resume "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'" \
    after-resume "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'"
