#!/bin/sh
set -eu

# Preserve automatic display sleep, including DVI-I-1 while the KVM is away.
exec swayidle -w \
    timeout 600 "hyprctl dispatch 'hl.dsp.dpms({ action = \"disable\" })'" \
    resume "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'" \
    after-resume "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'"
