#!/usr/bin/env bash
# Kamerafahrt + Zeitraffer der Einzelbäume (#236) als Video:
#
#   scripts/look/tree-flight.sh <ausgabe.mp4> [game-ordner]
#
# Godot schreibt mit fester Bildrate (30) ein MJPEG-AVI in Encoder-Größe
# 3456×2104 (project.godot, .movie-Overrides); ffmpeg macht daraus H.264.
# Ablauf: game/studies/trees/TreeFlight.gd. `RS_NO_TREES=1` nimmt denselben
# Ablauf mit dem Kronendach von #152 auf (Vergleich).
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
