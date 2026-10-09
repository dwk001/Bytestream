#!/bin/sh
# usage: tools/xshot.sh out.png [secs] [bytestream args...]  - captures the whole X screen (child controls included)
out="$1"; secs="${2:-4}"; shift; shift
export WINEDEBUG=-all WINEPREFIX="${WINEPREFIX:-/tmp/wineprefix}"
D=:77
Xvfb $D -screen 0 1400x900x24 >/dev/null 2>&1 &
xp=$!
sleep 1
DISPLAY=$D /usr/lib/wine/wine64 "$(dirname "$0")/../build/bytestream.exe" "$@" >/dev/null 2>&1 &
wp=$!
sleep "$secs"
DISPLAY=$D import -window root "$out"
kill $wp 2>/dev/null; wineserver -k 2>/dev/null; kill $xp 2>/dev/null
