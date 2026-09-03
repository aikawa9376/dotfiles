#!/bin/sh

# checkupdates refreshes a temporary repository database, while paru -Qua
# checks foreign packages against the AUR. Run them concurrently because both
# are network-bound and must not count the same repository upgrades twice.
cache_dir=${XDG_CACHE_HOME:-"$HOME/.cache"}/polybar/updates
mkdir -p "$cache_dir" || exit 1
last_count_file="$cache_dir/last-successful-count"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/polybar-updates.XXXXXX") || exit 1

cleanup() {
    rm -f \
        "$work_dir/repo.out" "$work_dir/repo.err" \
        "$work_dir/aur.out" "$work_dir/aur.err"
    rmdir "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

run_check() {
    source_name=$1
    no_updates_status=$2
    shift 2

    output_file="$work_dir/$source_name.out"
    error_file="$work_dir/$source_name.err"

    timeout 120 "$@" >"$output_file" 2>"$error_file"
    status=$?

    if [ "$status" -eq 0 ]; then
        return 0
    fi

    # checkupdates returns 2 and paru -Qua returns 1 when no updates exist.
    # The same statuses with an error message indicate a real failure.
    if [ "$status" -eq "$no_updates_status" ] && [ ! -s "$error_file" ]; then
        return 0
    fi

    return 1
}

print_count() {
    count=$1
    if [ "$count" -gt 0 ]; then
        printf '%s\n' "$count"
    else
        printf '\n'
    fi
}

print_last_count() {
    [ -r "$last_count_file" ] || {
        printf '\n'
        return
    }

    IFS= read -r count <"$last_count_file" || count=
    case $count in
        ''|*[!0-9]*) printf '\n' ;;
        *) print_count "$count" ;;
    esac
}

save_count() {
    count=$1
    count_file=$(mktemp "$cache_dir/.last-successful-count.XXXXXX") || return
    if printf '%s\n' "$count" >"$count_file"; then
        mv -f "$count_file" "$last_count_file"
    else
        rm -f "$count_file"
    fi
}

# Use a Polybar-owned database. The shared checkupdates database can be left
# with mismatched .db/.sig files when a refresh is interrupted, causing every
# later official-repository check to fail.
run_check repo 2 env CHECKUPDATES_DB="$cache_dir/checkupdates-db" \
    checkupdates --nocolor &
repo_pid=$!
run_check aur 1 paru -Qua &
aur_pid=$!

repo_ok=true
aur_ok=true
wait "$repo_pid" || repo_ok=false
wait "$aur_pid" || aur_ok=false

# A partial count is misleading (for example, an AUR-only number when the
# repository sync failed). During startup or another transient network failure,
# keep showing the last complete result instead. With no saved result, hide the
# count until a complete check succeeds.
if [ "$repo_ok" != true ] || [ "$aur_ok" != true ]; then
    print_last_count
    exit 0
fi

updates_repo=$(awk 'NF { count++ } END { print count + 0 }' "$work_dir/repo.out")
updates_aur=$(awk 'NF { count++ } END { print count + 0 }' "$work_dir/aur.out")
updates=$((updates_repo + updates_aur))

save_count "$updates"
print_count "$updates"
