#! /bin/sh

if sessionlist=$(tmux ls); then
    windowlist=$(tmux lsw)

    sessionnum=$(echo "$sessionlist" | wc -l)
    sessionnow=$(echo "$sessionlist" | grep -n "(attached)" | sed -e 's/:.*//g')

    windownum=$(echo "$windowlist" | wc -l)
    windownow=$(echo "$windowlist" | grep -n "*" | sed -e 's/:.*//g')
    window=$(echo "$windowlist" | grep -n "*" | sed -E 's/^.*: (.*)\*.*$/\1/g')

    echo "$sessionlist" | while read -r line; do
        session=$(echo "$line" | cut -d ':' -f 1)

        if echo "$line" | grep -q "(attached)"; then
            printf "%s-%s [%s:%s][%s:%s]" "$session" "$window" "$windownow" "$windownum" "$sessionnow" "$sessionnum"
        fi
    done

else
    printf ""
fi
