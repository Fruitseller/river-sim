#!/usr/bin/env bash
# Frame-Zeiten im Zeitraffer als interleaved A/B (Messprotokoll:
# docs/perf-measurements.md, Abschnitt L).
#
#   scripts/timelapse-timing.sh [SPIELORDNER …]
#
# Ohne Argument misst es `game/` dieses Checkouts. Mit mehreren Ordnern läuft
# je Runde jeder Ordner einmal, die Reihenfolge wechselt von Runde zu Runde
# (A B, B A, A B, …): so trifft eine Lastspitze anderer Prozesse beide Stände
# gleich. Ein Vergleichsstand ist eine Kopie von `game/` samt `bin/` und
# importiertem `.godot/` (z. B. `cp -R game /tmp/alt/game` vor dem Umbau).
#
# Gemessen wird mit der Flusstal-Bühne im Betrieb `simulation` (60 J./Sek. ab
# Sekunde 2, Frame-Abstände über 10 s, `game/studies/flusstal/Flusstal.gd`),
# maximiert, wie es AGENTS.md für Bildraten verlangt. Bewusst OHNE
# `scripts/start.sh`: dessen Build-Stempel-Prüfung lehnt jeden Vergleichsstand
# ab, dessen Quellen nicht die des Arbeitsverzeichnisses sind.
#
# Umgebung (alle optional):
#   RS_TIMING_RUNS    Runden (Standard 5)
#   RS_TIMING_SEED    Welt (Standard 1337)
#   RS_TIMING_YEAR    Vorlauf in Jahren (Standard 20000)
#   RS_TIMING_CAMERA  "ziel;distanz;yaw;pitch" (Standard: Matrix-Kamera
#                     `detail` von Seed 1337, s. scripts/graphics-matrix.sh)
#   RS_TIMING_QUALITY performance|balanced|quality (Standard balanced)
#   RS_TIMING_OUT     Ergebnisordner (Standard /tmp/rs-timelapse-timing)
#   RS_TIMING_SCREEN  Bildschirm-Index für `--screen` (Standard: Godots Wahl).
#                     Mit externem Monitor startet Godot dort; der eingebaute
#                     Bildschirm des Referenz-Macs ist dann z. B. Index 1
#                     (maximiert 3456×2104). Die Viewport-Größe steht in
#                     jeder Ergebniszeile.
#   GODOT             Godot-Binärdatei (Standard: scripts/fetch-godot.sh --path)
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-$(scripts/fetch-godot.sh --path)}"
runs="${RS_TIMING_RUNS:-5}"
seed="${RS_TIMING_SEED:-1337}"
year="${RS_TIMING_YEAR:-20000}"
camera="${RS_TIMING_CAMERA:--12,-25;42.0;0.7;0.85}"
quality="${RS_TIMING_QUALITY:-balanced}"
out_dir="${RS_TIMING_OUT:-/tmp/rs-timelapse-timing}"
screen_args=()
if [[ -n "${RS_TIMING_SCREEN:-}" ]]; then
  screen_args=(--screen "$RS_TIMING_SCREEN")
fi
IFS=';' read -r target dist yaw pitch <<< "$camera"

games=("$@")
if [[ ${#games[@]} -eq 0 ]]; then
  games=("game")
fi
for g in "${games[@]}"; do
  if [[ ! -f "$g/project.godot" ]]; then
    echo "Kein Godot-Projekt: $g" >&2
    exit 2
  fi
done

mkdir -p "$out_dir"
labels=()
for i in "${!games[@]}"; do
  labels+=("$(printf "\\x$(printf %x $((65 + i)))")")
  : > "$out_dir/${labels[$i]}.jsonl"
  echo "${labels[$i]} = ${games[$i]}"
done

for ((round = 0; round < runs; round++)); do
  order=("${!games[@]}")
  if ((round % 2 == 1)); then
    # umgekehrte Reihenfolge in jeder zweiten Runde
    rev=()
    for ((k = ${#order[@]} - 1; k >= 0; k--)); do rev+=("${order[$k]}"); done
    order=("${rev[@]}")
  fi
  for i in "${order[@]}"; do
    load="$(uptime | sed 's/.*load averages*: *//')"
    echo "==> Runde $((round + 1))/$runs, ${labels[$i]} (${games[$i]}), Last: $load"
    line="$(env -u RS_SHOT -u RS_FPS -u RS_IDLE -u RS_FLATTEN -u RS_WATER_STAMP \
        -u RS_WATER_GPU -u RS_RENDER_GRID -u RS_DEBUG_DIFF -u RS_DIAG -u RS_STUDY_DEBUG \
        RS_SEED="$seed" RS_STEP="$year" RS_STEP_CHUNK=1000 RS_QUALITY="$quality" \
        RS_TARGET="$target" RS_DIST="$dist" RS_YAW="$yaw" RS_PITCH="$pitch" \
        RS_STUDY_VARIANT=baseline RS_STUDY_MODE=simulation RS_STUDY_OUTPUT= \
        "$GODOT" --path "${games[$i]}" ${screen_args[@]+"${screen_args[@]}"} --maximized res://studies/flusstal/Flusstal.tscn 2>&1 \
        | { grep '^STUDY_TIMING ' || true; } | sed 's/^STUDY_TIMING //' | tail -1)"
    if [[ -z "$line" ]]; then
      echo "Keine STUDY_TIMING-Zeile (${games[$i]})" >&2
      exit 1
    fi
    # Lastmittel zum Lauf mitschreiben: auf einem belasteten Rechner ist es
    # Teil des Ergebnisses.
    echo "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["load"]=sys.argv[1]; print(json.dumps(d))' "$load" \
      >> "$out_dir/${labels[$i]}.jsonl"
    echo "    $line"
  done
done

python3 - "$out_dir" "${labels[@]}" <<'PY'
import json, statistics, sys
out_dir, labels = sys.argv[1], sys.argv[2:]
keys = [("mean_ms", "Mittel"), ("p95_ms", "p95"), ("p99_ms", "p99"),
        ("max_ms", "Max"), ("over_budget_frames", "> 33,3 ms")]
# Nur ein Stand mit Hintergrund-Schritt meldet diese Werte (sonst „–").
extra = [("apply_median_ms", "Hochladen Median"), ("apply_max_ms", "Hochladen Max"),
         ("apply_frame_max_ms", "Upload-Frame Max"), ("step_wait_ms", "Hauptthread wartet")]
print()
print("Median über die Läufe (je Lauf: Frame-Abstände über 10 s Zeitraffer)")
print("| Stand | Läufe | " + " | ".join(k[1] for k in keys + extra) + " | Last (1 min) | Viewport |")
print("| --- | ---: | " + " | ".join("---:" for _ in keys + extra) + " | ---: | --- |")
for label in labels:
    rows = [json.loads(l) for l in open(f"{out_dir}/{label}.jsonl") if l.strip()]
    if not rows:
        continue
    cells = []
    for key, _ in keys + extra:
        values = [r[key] for r in rows if key in r]
        if not values:
            cells.append("–")
            continue
        value = statistics.median(values)
        cells.append(f"{value:.0f}" if key == "over_budget_frames" else f"{value:.1f} ms")
    loads = [float(r["load"].replace(",", ".").split()[0]) for r in rows if "load" in r]
    load = f"{statistics.median(loads):.1f}" if loads else "–"
    print(f"| {label} | {len(rows)} | " + " | ".join(cells) + f" | {load} | {rows[0]['viewport']} |")
PY
