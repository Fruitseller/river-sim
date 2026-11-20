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
# Schläft der Bildschirm, drosselt macOS das Fenster: eine Aufnahme dauerte
# gemessen 16 min statt 20 s. Also wecken und für die Dauer wach halten.
wach=()
if command -v caffeinate >/dev/null; then caffeinate -u -t 3; wach=(caffeinate -d); fi

# `RS_LOOK_BACKGROUND=1` startet Godot unter macOS über `open -g`, damit das
# Fenster nicht dauerhaft vorn liegt (dazu Godot im Dock einem eigenen
# Desktop zuweisen). Noch kein Standard, gemessen 2026-11-20: Godot holt sich
# beim Start trotzdem kurz den Fokus (6 von 40 Stichproben über drei
# Aufnahmen), und `nah` kommt um wenige Pixel verschoben heraus (PSNR 18
# gegen den Direktstart, dessen Wiederholung 38 erreicht; Ursache offen).
# A und B eines Vergleichs deshalb immer auf DEMSELBEN Weg aufnehmen.
hintergrund=0; app=${godot%/Contents/MacOS/*}
if [[ -n ${RS_LOOK_BACKGROUND:-} && $app == *.app ]] && command -v open >/dev/null; then hintergrund=1; fi

# name | Referenz | Umgebung der Kamera
shots=(
  "diorama|d-insel-diorama-schoen.jpg|RS_CAMERA=diorama"
  "tal|e-tal-kueste-schoen.jpg|RS_CAMERA=valley"
  "nah|f-nah-flussschleife-schoen.jpg|RS_TARGET=17,10 RS_PITCH=0.55 RS_YAW=0 RS_DIST=16"
)
for s in "${shots[@]}"; do
  IFS='|' read -r name _ cam <<<"$s"
  if (( hintergrund )); then
    envs=()
    for kv in RS_SEED=1337 RS_STEP=20000 $cam "RS_SHOT=$out/$name.png"; do envs+=(--env "$kv"); done
    "${wach[@]}" open -g -n -W -a "$app" --stdout "$out/$name.log" --stderr "$out/$name.log" \
      "${envs[@]}" --args --path "$game" --maximized || true
  else
    # shellcheck disable=SC2086
    "${wach[@]}" env RS_SEED=1337 RS_STEP=20000 $cam RS_SHOT="$out/$name.png" \
      "$godot" --path "$game" --maximized >"$out/$name.log" 2>&1 || true
  fi
  [[ -s "$out/$name.png" ]] || { echo "FEHLT: $out/$name.png (Log: $out/$name.log)" >&2; exit 1; }
  sips -Z 2048 -s format jpeg -s formatOptions 90 "$out/$name.png" --out "$out/$name.jpg" >/dev/null
  echo "$name: $out/$name.jpg"
done
