#!/usr/bin/env bash
set -euo pipefail
out=${1:?Ausgabe fehlt}
root=$(cd "$(dirname "$0")/../.." && pwd)
game=${2:-$root/game}
godot=${GODOT:-$root/.tools/godot-macos/Godot.app/Contents/MacOS/Godot}
avi="${out%.*}.avi"
wach=()
if command -v caffeinate >/dev/null; then caffeinate -u -t 3; wach=(caffeinate -d); fi
"${wach[@]}" env RS_SEED=1337 RS_STEP=20000 RS_QUALITY=balanced \
  "$godot" --path "$game" --maximized --resolution 3456x2104 \
  --write-movie "$avi" --fixed-fps 30 res://studies/trees/TreeFlight.tscn \
  >"${out%.*}.log" 2>&1 || true
[[ -s "$avi" ]] || { echo "FEHLT: $avi (Log: ${out%.*}.log)" >&2; exit 1; }
ffmpeg -loglevel error -y -i "$avi" -vf scale=1728:-2 -c:v libx264 -crf 22 -pix_fmt yuv420p "$out"
rm -f "$avi"
echo "$out"
