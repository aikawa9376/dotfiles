#! /bin/sh

isMozc=$(fcitx-remote)

if [[ $isMozc == 2 ]]; then
  echo "MOZC"
else
  echo ""
fi
