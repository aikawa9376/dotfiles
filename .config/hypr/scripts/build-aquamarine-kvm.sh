#!/bin/sh
set -eu

hypr_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=0.15.0
if [ "$(pkg-config --modversion aquamarine)" != "$version" ]; then
    printf 'This patch requires aquamarine %s; rebase it before rebuilding.\n' "$version" >&2
    exit 1
fi
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
curl -fL --max-time 60 "https://github.com/hyprwm/aquamarine/archive/refs/tags/v$version.tar.gz" -o "$work_dir/source.tar.gz"
printf '%s  %s\n' bb5323f58cd2f379cb11c39893336e49980fe2e9fb101745addd87cebde3d13d "$work_dir/source.tar.gz" | sha256sum -c -
tar -xzf "$work_dir/source.tar.gz" -C "$work_dir"
patch -d "$work_dir/aquamarine-$version" -p1 < "$hypr_dir/patches/aquamarine-$version-preserve-crtc.patch"
cmake -S "$work_dir/aquamarine-$version" -B "$work_dir/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$work_dir/build" -j 2 --target aquamarine attachments output commitThread
ctest --test-dir "$work_dir/build" --output-on-failure -R '^(attachments|output|commitThread)$'

# Keep binaries out of git and never overwrite a library mapped by a session.
mkdir -p "$hypr_dir/lib"
stage=$(mktemp -d "$hypr_dir/lib/build.XXXXXX")
cp -a "$work_dir/build/"libaquamarine.so* "$stage/"
# Include all linked runtime libraries, not just the C++ Hyprutils dependency.
ldd "$stage/libaquamarine.so.14" > "$work_dir/ldd"
if grep -q 'not found' "$work_dir/ldd"; then
    cat "$work_dir/ldd" >&2
    exit 1
fi
awk '/=> \// { print $3 }' "$work_dir/ldd" | xargs pacman -Qoq > "$work_dir/owners"
printf '%s\n' aquamarine hyprland >> "$work_dir/owners"
sort -u "$work_dir/owners" | xargs pacman -Q > "$stage/packages"
ln -sfn "$(basename "$stage")" "$hypr_dir/lib/current"
printf 'Built %s; restart the Hyprland session to load it.\n' "$stage"
