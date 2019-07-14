#! /bin/sh

if sessionlist=$(tmux ls); then

    sessionnum=$(echo "$sessionlist" | wc -l)
    sessionnow=$(echo "$sessionlist" | grep -n "(attached)" | sed -e 's/:.*//g')

    echo "$sessionlist" | while read -r line; do
        session=$(echo "$line" | cut -d ':' -f 1)

        if echo "$line" | grep -q "(attached)"; then
            printf "%s [%s:%s]" "$session" "$sessionnow" "$sessionnum"
        fi
    done

else
    printf ""
fi
