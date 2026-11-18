#!/usr/bin/env bash
# Feste Aufnahmen für den visuellen Hill-Climber (Referenzen:
# docs/references/zielbild/README.md § Aufgehübschte Spielbilder).
#
#   scripts/look/shots.sh <ausgabe-ordner> [game-ordner]
#
# Rendert je Kamera ein PNG (maximiert, ohne UI) und ein JPG mit 2048 px
# Breite für den Bewerter. Seed 1337, Jahr 20.000 wie die Referenzen.
# Der optionale game-Ordner erlaubt A/B gegen eine Kopie des alten Stands
# (cp -R game /tmp/alt/game, mit bin/ und .godot/).
set -euo pipefail
out=${1:?Ausgabe-Ordner fehlt}
root=$(cd "$(dirname "$0")/../.." && pwd)
game=${2:-$root/game}
godot=${GODOT:-$root/.tools/godot-macos/Godot.app/Contents/MacOS/Godot}
mkdir -p "$out"

# name | Referenz | Umgebung der Kamera
shots=(
  "diorama|d-insel-diorama-schoen.jpg|RS_CAMERA=diorama"
  "tal|e-tal-kueste-schoen.jpg|RS_CAMERA=valley"
  "nah|f-nah-flussschleife-schoen.jpg|RS_TARGET=17,10 RS_PITCH=0.55 RS_YAW=0 RS_DIST=16"
)
for s in "${shots[@]}"; do
  IFS='|' read -r name _ cam <<<"$s"
  # shellcheck disable=SC2086
  env RS_SEED=1337 RS_STEP=20000 $cam RS_SHOT="$out/$name.png" \
    "$godot" --path "$game" --maximized >"$out/$name.log" 2>&1 || true
  [[ -s "$out/$name.png" ]] || { echo "FEHLT: $out/$name.png (Log: $out/$name.log)" >&2; exit 1; }
  sips -Z 2048 -s format jpeg -s formatOptions 90 "$out/$name.png" --out "$out/$name.jpg" >/dev/null
  echo "$name: $out/$name.jpg"
done
