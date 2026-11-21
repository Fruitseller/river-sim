#!/usr/bin/env bash
# Zeitraffer-Video aus fester Kamera, in Echtzeit aufgenommen, für den
# Flimmer-Vergleich der Gelände-Verfeinerung (#238) und als Beleg im PR.
#
#   scripts/look/zeitraffer-video.sh <ausgabe.mp4> [nah|tal|diorama] [sekunden] [game-ordner]
#
# Seed 1337 ab Jahr 20.000 wie scripts/look/shots.sh, Zeitraffer mit RS_RATE
# (Standard 60 J./Sek.), Fenster 1728×1052. Die Umgebung reicht durch:
# `RS_AMPLIFY=0` nimmt den alten Back-Pass, damit vergleicht man alt gegen
# neu im selben Build. Aufgenommen wird mit game/tools/timelapse_capture.gd
# (warum nicht `--write-movie`, steht dort). Auswertung: scripts/look/flimmern.py.
set -euo pipefail
out=${1:?Ausgabe fehlt}
cam=${2:-nah}
sek=${3:-12}
root=$(cd "$(dirname "$0")/../.." && pwd)
game=${4:-$root/game}
godot=${GODOT:-$root/.tools/godot-macos/Godot.app/Contents/MacOS/Godot}
case $cam in
  nah) kamera="RS_TARGET=17,10 RS_PITCH=0.55 RS_YAW=0 RS_DIST=16" ;;
  tal) kamera="RS_CAMERA=valley" ;;
  diorama) kamera="RS_CAMERA=diorama" ;;
  *) echo "Kamera: nah, tal oder diorama" >&2; exit 2 ;;
esac
# Messungen anderer Stränge nicht stören (Sperre aus den Arbeitsregeln).
while [[ -d /tmp/river-sim-gpu.lock ]]; do sleep 1; done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zeitraffer.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
wach=()
if command -v caffeinate >/dev/null; then caffeinate -u -t 3; wach=(caffeinate -d); fi
# shellcheck disable=SC2086
"${wach[@]}" env RS_SEED=1337 RS_STEP=20000 RS_RATE="${RS_RATE:-60}" $kamera \
  CAPTURE_OUT="$tmp/bilder" CAPTURE_SECONDS="$sek" \
  "$godot" --path "$game" --resolution 1728x1052 \
  --script res://tools/timelapse_capture.gd >"$tmp/log.txt" 2>&1 || true
n=$(find "$tmp/bilder" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')
(( n > 10 )) || { cat "$tmp/log.txt" >&2; echo "FEHLT: keine Bilder" >&2; exit 1; }
# Gleichmäßige Bildrate aus Bildzahl und Dauer: die Aufnahme bremst das
# Spiel, die Abstände schwanken um wenige Millisekunden.
fps=$(python3 -c "print(round($n / $sek, 3))")
ffmpeg -loglevel error -y -framerate "$fps" -i "$tmp/bilder/%05d.jpg" -an \
  -c:v libx264 -crf 16 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" "$out"
echo "$out ($n Bilder, $fps Bilder je Sekunde)"
