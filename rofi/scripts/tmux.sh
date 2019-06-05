#!/bin/bash
if [[ $# -eq 0 ]]; then
  sessions=$(tmux list-sessions)
  echo "$sessions" | sed -e 's/:.*20[0-9].)//g' | tr ')' ')\n' | sort -n
  exit 0
fi

SELECTED=$1
# SELECTED="sirayuri"
TMUXDIR=
FOUND=0

## - Check if user selection match with session mapping.
## - Get session working directory
SELECTED=$(echo "$SELECTED" | cut -f 1 -d ':')
$(tmux switch-client -t $SELECTED)
FOUND=1

if (( $FOUND == 0 )); then
  echo "$sessions" | tr ')' ')\n' | sort -n
	exit 1
fi

xdotool search --onlyvisible --class "Alacritty" windowactivate
