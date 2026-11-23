#!/usr/bin/env bash
set -euo pipefail
out=${1:?Ausgabe-Ordner fehlt}
root=$(cd "$(dirname "$0")/../.." && pwd)
game=${2:-$root/game}
godot=${GODOT:-$root/.tools/godot-macos/Godot.app/Contents/MacOS/Godot}
mkdir -p "$out"
wach=()
if command -v caffeinate >/dev/null; then caffeinate -u -t 3; wach=(caffeinate -d); fi

hintergrund=0; app=${godot%/Contents/MacOS/*}
if [[ -n ${RS_LOOK_BACKGROUND:-} && $app == *.app ]] && command -v open >/dev/null; then hintergrund=1; fi

shots=(
  "diorama|d-insel-diorama-schoen.jpg|RS_CAMERA=diorama"
  "tal|e-tal-kueste-schoen.jpg|RS_CAMERA=valley"
  "nah|f-nah-flussschleife-schoen.jpg|RS_TARGET=17,10 RS_PITCH=0.55 RS_YAW=0 RS_DIST=16"
)
for s in "${shots[@]}"; do
  IFS='|' read -r name _ cam <<<"$s"
  rm -f "$out/$name.png" "$out/$name.jpg"
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
