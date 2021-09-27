#! /bin/sh

isMozc=$(fcitx5-remote)

if [[ $isMozc == 2 ]]; then
  echo "MOZC"
else
  echo ""
fi
