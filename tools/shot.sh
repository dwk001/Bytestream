#!/bin/sh
# usage: tools/shot.sh out.png [bytestream args...]   - renders one frame under Wine+Xvfb and saves a PNG
out="$1"; shift
export WINEDEBUG=-all WINEPREFIX="${WINEPREFIX:-/tmp/wineprefix}"
bmp="${out%.png}.bmp"
rm -f "$bmp"
xvfb-run -a -s "-screen 0 1920x1080x24" timeout 90 /usr/lib/wine/wine64 "$(dirname "$0")/../build/bytestream.exe" "$@" --screenshot "$bmp" >/dev/null 2>&1
[ -f "$bmp" ] || { echo "no screenshot produced"; exit 1; }
python3 "$(dirname "$0")/bmp2png.py" "$bmp" "$out"
rm -f "$bmp"
