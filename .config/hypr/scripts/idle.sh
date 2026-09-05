#!/bin/sh
set -eu

exec swayidle -w \
    timeout 600 "hyprctl dispatch 'hl.dsp.dpms({ action = \"disable\" })'" \
    resume "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'"
