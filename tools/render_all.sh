#!/bin/sh
# Renders every screen of the demo build to PNGs in $1 (default /tmp/shots).
d="${1:-/tmp/shots}"; mkdir -p "$d"; here="$(dirname "$0")"
s() { n="$1"; shift; "$here/shot.sh" "$d/$n.png" "$@" >/dev/null || echo "FAILED $n"; }
s home        --demo --play --seek 83
s search      --demo --page 1 --search q --play
s library     --demo --page 2 --tab 0
s liked       --demo --page 2 --tab 1 --play
s albums      --demo --page 2 --tab 2
s detail      --demo --detail 2 --play --seek 40
s settings    --demo --page 4
s login       
s fullscreen  --demo --play --seek 61 --fullscreen
s queue       --demo --play --queue --seek 20
s midnight    --demo --play --theme 1 --seek 83
s light       --demo --play --theme 2 --seek 83
s hover       --demo --play --hover 350,200
s hidpi       --demo --play --scale 150 --size 1500x900
echo rendered to "$d"
