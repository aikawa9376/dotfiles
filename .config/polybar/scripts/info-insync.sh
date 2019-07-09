#! /bin/sh

insync=$(insync get_status)

if [[ $insync == "ERROR" ]]; then
  echo "%{F#d64937}罹%{F-}"
elif [[ $insync == "OFFLINE" ]]; then
  echo "%{F#d64937}裏%{F-}"
elif [[ $insync == "PAUSED" ]]; then
  echo "%{F#4F8F57}%{F-}"
elif [[ $insync == "SYNCING" ]]; then
  num="%{F#55}痢%{F-} $(insync get_sync_progress | sed -n '$p' | cut -f 1 -d ' ')"
  echo $num
elif [[ $insync == "SYNCED" ]]; then
  echo "%{F#55}%{F-}"
elif [[ $insync == "ACTION" ]]; then
  echo "%{F#55}%{F-}"
else
  echo ""
fi
