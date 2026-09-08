#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$module_dir/calendar.so" ] || [ "$module_dir/calendar.c" -nt "$module_dir/calendar.so" ]; then
    temporary=$(mktemp "$module_dir/calendar.so.XXXXXX")
    trap 'rm -f "$temporary"' EXIT HUP INT TERM
    # pkg-config emits compiler arguments; intentional word splitting.
    cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared \
        "$module_dir/calendar.c" -o "$temporary" $(pkg-config --cflags --libs gtk+-3.0)
    mv "$temporary" "$module_dir/calendar.so"
fi
