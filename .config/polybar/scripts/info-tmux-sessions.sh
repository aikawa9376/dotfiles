#! /bin/sh

# Control clients (for example agent observers) are not interactive terminals.
# With multiple terminals, show the session of the most recently active one.
session=$(tmux list-clients -F '#{client_control_mode} #{client_activity} #{session_id}' 2>/dev/null |
    awk '$1 == 0 && $2 >= activity { activity = $2; session = $3 }
         END { print session }')
[ -n "$session" ] || exit 0

# Read explicit fields from the same snapshot, rather than parsing tmux's
# human-readable output or relying on the inherited TMUX target.
tab=$(printf '\t')
tmux list-windows -a -F "#{session_id}${tab}#{session_name}${tab}#{window_active}${tab}#{window_name}" 2>/dev/null |
    awk -F '\t' -v selected="$session" '
        !($1 in sessions) { sessions[$1] = ++total }
        $1 == selected {
            name = $2
            windows++
            if ($3 == 1) {
                active = windows
                window = $4
            }
        }
        END {
            if (active)
                printf "%s-%s [%d:%d][%d:%d]\n", name, window,
                    active, windows, sessions[selected], total
        }'
