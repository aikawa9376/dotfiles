#!/bin/bash

base=`basename $0 | sed -e 's/\.sh$//g'`
cmd=`echo $base | awk -F '_' '{print $1}'`
keystroke=`echo $base | sed -e 's/^[^_]\+_//g'`

id=`xdotool getwindowfocus`
case $cmd in
key)
  xdotool key --window $id "$keystroke" > /dev/null 2>&1
  ;;
type)
  echo -n "$keystroke" | xclip -i -selection clipboard
  xdotool key --window $id "ctrl+v" > /dev/null 2>&1
  ;;
*)
	echo "usage: ln -s $0 {key|type}_<keystroke>.sh"
	exit 1;;
esac
