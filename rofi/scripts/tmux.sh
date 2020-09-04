#!/bin/bash
if [[ $# -eq 0 ]]; then
  sessions=$(tmux list-sessions)
  while read -r line; do
    name=$(echo "$line" | sed -e 's/:.*20[0-9].)//g' | tr ')' ')\n' | sed -e 's/ (attached)//g')
    window=$(tmux list-window -t "$name")
    num=$(echo "$window" | wc -l)
    if [ ${num} -ne 1 ]; then
      while read -r line; do
        window=$(echo "$line" | sed -E 's/(^.*): (.*) .*$/\1:\2/g' | cut -d ' ' -f 1)
        echo $name":"$window
      done < <(echo "$window")
    else
      echo $name
    fi
  done < <(echo "$sessions")
  exit 0
fi

SELECTED=$1
# SELECTED="sirayuri"
TMUXDIR=
FOUND=0

## - Check if user selection match with session mapping.
## - Get session working directory
SESSION=$(echo "$SELECTED" | cut -f 1 -d ':')
WINDOW=$(echo "$SELECTED" | cut -f 2 -d ':' | sed -r 's/[\*-]//g' )
$(tmux switch-client -t $SESSION)
$(tmux select-window -t $WINDOW)
FOUND=1

if (( $FOUND == 0 )); then
  echo "$sessions" | tr ')' ')\n' | sort -n
	exit 1
fi

xdotool search --onlyvisible --class "Alacritty" windowactivate
