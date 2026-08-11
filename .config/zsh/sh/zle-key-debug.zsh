#!/usr/bin/zsh -f
# Print terminal input bytes for 20 seconds, then restore the keyboard mode.
# Usage: ~/.config/zsh/sh/zle-key-debug.zsh [auto|kitty|tmux|legacy]

set -u

mode=${1:-auto}
duration=${ZLE_KEY_DEBUG_SECONDS:-20}
saved_tty=$(stty -g)
typeset -gi marked=0

if [[ $mode == auto ]]; then
  if [[ -n ${TMUX:-} ]]; then
    mode=tmux
  elif [[ -n ${KITTY_WINDOW_ID:-} ]]; then
    mode=kitty
  else
    mode=legacy
  fi
fi

cleanup() {
  if [[ $mode == kitty ]]; then
    print -rn -- $'\e[<u' > /dev/tty
  elif [[ $mode == tmux ]]; then
    print -rn -- $'\e[>4m' > /dev/tty
    if (( marked )) && [[ -n ${TMUX_PANE:-} ]]; then
      command tmux set-option -pu -t "$TMUX_PANE" @zle_csi_u 2>/dev/null
    fi
  fi
  stty "$saved_tty"
}
trap cleanup EXIT INT TERM HUP

stty raw -echo
if [[ $mode == kitty ]]; then
  print -rn -- $'\e[>1u' > /dev/tty
elif [[ $mode == tmux ]]; then
  if [[ -n ${TMUX_PANE:-} ]]; then
    command tmux set-option -p -t "$TMUX_PANE" @zle_csi_u 1 2>/dev/null
    marked=1
  fi
  print -rn -- $'\e[>4;2m' > /dev/tty
fi

print -ru2 -- "capturing $mode input for ${duration}s (hex bytes):"
timeout "$duration" dd bs=1 status=none | stdbuf -o0 od -An -v -tx1
