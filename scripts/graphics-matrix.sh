#!/usr/bin/env bash
# Reproduzierbare Abnahmematrix für Landschaftsqualität (Issue #150, Spec #156, Parent #117).
# Startet für eine Variante alle Vergleichswelten und Kameraperspektiven.
set -euo pipefail
cd "$(dirname "$0")/.."

variant="${1:-baseline}"
output_dir="${2:-docs/screenshots/graphics-matrix/$variant}"
mode="${3:-shot}"

case "$variant" in baseline|prototype) ;; *) echo "Variante: baseline|prototype" >&2; exit 2;; esac
case "$mode" in shot|timing|all|list) ;; *) echo "Modus: shot|timing|all|list" >&2; exit 2;; esac

# Optionale Filter über Umgebungsvariablen
filter_seed="${RS_MATRIX_SEED:-}"
filter_year="${RS_MATRIX_YEAR:-}"
filter_camera="${RS_MATRIX_CAMERA:-}"
dry_run="${RS_MATRIX_DRY_RUN:-0}"

# Matrix-Definition: Seeds
seeds=(1337 42 20)
declare -A seed_names=(
  [1337]="Flusstal Soča"
  [42]="Seen- und Beckenplateau"
  [20]="Hochalpines Massiv"
)

# Matrix-Definition: Jahre
years=(0 20000 100000)
declare -A year_labels=(
  [0]="0k"
  [20000]="20k"
  [100000]="100k"
)

# Kameras je Seed (target;dist;yaw;pitch;sun)
declare -A cameras_1337=(
  [overview]="0,0;151.846515;0.7;0.85;"
  [detail]="-12,-25;42.0;0.7;0.85;"
  [grazing]="-10,-20;38.0;0.7;1.35;"
  [backlight]="-12,-25;45.0;-0.87;0.85;-50,28"
  [coast]="-36,-32;45.0;0.9;0.85;"
  [snow]="18,14;48.0;0.6;0.75;"
)

declare -A cameras_42=(
  [overview]="0,0;151.846515;0.7;0.85;"
  [detail]="4,-6;45.0;0.5;0.80;"
  [grazing]="6,-4;40.0;0.4;1.35;"
  [backlight]="4,-6;48.0;-0.87;0.85;-50,28"
  [coast]="12,-10;38.0;1.1;0.85;"
  [snow]="-22,20;50.0;0.7;0.75;"
)

declare -A cameras_20=(
  [overview]="0,0;151.846515;0.7;0.85;"
  [detail]="-8,10;42.0;0.6;0.80;"
  [grazing]="-6,12;38.0;0.5;1.35;"
  [backlight]="-8,10;46.0;-0.87;0.85;-50,28"
  [coast]="30,-28;48.0;0.8;0.85;"
  [snow]="-10,14;40.0;0.6;0.70;"
)

camera_order=(overview detail grazing backlight coast snow)

if [[ "$mode" == "list" ]]; then
  echo "Abnahmematrix (Landschaftsqualität #150):"
  echo "Variante: $variant"
  echo "Ausgabepfad: $output_dir"
  for s in "${seeds[@]}"; do
    echo "--- Seed $s (${seed_names[$s]}) ---"
    for y in "${years[@]}"; do
      ylabel="${year_labels[$y]}"
      echo "  Stadium Jahr $y ($ylabel):"
      for c in "${camera_order[@]}"; do
        echo "    - $c -> seed${s}_${ylabel}_${c}.png"
      done
    done
  done
  exit 0
fi

mkdir -p "$output_dir"

run_shot() {
  local s="$1" y="$2" ylabel="$3" c="$4" cfg="$5"
  local target dist yaw pitch sun
  IFS=';' read -r target dist yaw pitch sun <<< "$cfg"

  local out_base="$output_dir/seed${s}_${ylabel}_${c}"
  echo "==> [SHOT] Seed $s (${seed_names[$s]}) | Jahr $y ($ylabel) | Kamera $c"
  echo "    Ziel: $target | Dist: $dist | Yaw: $yaw | Pitch: $pitch | Aus: ${out_base}.png"

  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  unset RS_SHOT RS_FPS RS_IDLE RS_FLATTEN RS_WATER_STAMP RS_WATER_GPU RS_RENDER_GRID RS_DEBUG_DIFF RS_NO_MEANDER_PAINT RS_DIAG \
        RS_STUDY_GRID RS_STUDY_LEVERS RS_STUDY_RELIEF RS_STUDY_DEBUG RS_STUDY_MOVIE
  export RS_SEED="$s" RS_STEP="$y" RS_STEP_CHUNK=1000 RS_QUALITY=balanced
  export RS_TARGET="$target" RS_DIST="$dist" RS_YAW="$yaw" RS_PITCH="$pitch"
  if [[ -n "$sun" ]]; then
    export RS_STUDY_SUN="$sun"
  else
    unset RS_STUDY_SUN
  fi
  export RS_STUDY_VARIANT="$variant" RS_STUDY_MODE="shot" RS_STUDY_OUTPUT="$out_base"

  scripts/start.sh --maximized res://studies/flusstal/Flusstal.tscn
}

run_timing() {
  local s="$1" y="$2" ylabel="$3" timing_mode="$4"
  # Timing-Messung auf der Hauptansicht (detail bzw. overview)
  local cfg="${cameras_1337[detail]}"
  if [[ "$s" == "42" ]]; then cfg="${cameras_42[detail]}"; fi
  if [[ "$s" == "20" ]]; then cfg="${cameras_20[detail]}"; fi
  local target dist yaw pitch sun
  IFS=';' read -r target dist yaw pitch sun <<< "$cfg"

  echo "==> [TIMING:$timing_mode] Seed $s (${seed_names[$s]}) | Jahr $y ($ylabel)"

  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  unset RS_SHOT RS_FPS RS_IDLE RS_FLATTEN RS_WATER_STAMP RS_WATER_GPU RS_RENDER_GRID RS_DEBUG_DIFF RS_NO_MEANDER_PAINT RS_DIAG \
        RS_STUDY_GRID RS_STUDY_LEVERS RS_STUDY_RELIEF RS_STUDY_DEBUG RS_STUDY_MOVIE
  export RS_SEED="$s" RS_STEP="$y" RS_STEP_CHUNK=1000 RS_QUALITY=balanced
  export RS_TARGET="$target" RS_DIST="$dist" RS_YAW="$yaw" RS_PITCH="$pitch"
  unset RS_STUDY_SUN
  export RS_STUDY_VARIANT="$variant" RS_STUDY_MODE="$timing_mode" RS_STUDY_OUTPUT=""

  scripts/start.sh --maximized res://studies/flusstal/Flusstal.tscn
}

# 1. Bilderzeugung (shot)
if [[ "$mode" == "shot" || "$mode" == "all" ]]; then
  echo "Starte Matrix-Bildgenerierung (Variante: $variant)..."
  for s in "${seeds[@]}"; do
    if [[ -n "$filter_seed" && "$s" != "$filter_seed" ]]; then continue; fi

    for y in "${years[@]}"; do
      if [[ -n "$filter_year" && "$y" != "$filter_year" ]]; then continue; fi
      ylabel="${year_labels[$y]}"

      for c in "${camera_order[@]}"; do
        if [[ -n "$filter_camera" && "$c" != "$filter_camera" ]]; then continue; fi

        cfg=""
        case "$s" in
          1337) cfg="${cameras_1337[$c]}" ;;
          42)   cfg="${cameras_42[$c]}" ;;
          20)   cfg="${cameras_20[$c]}" ;;
        esac

        run_shot "$s" "$y" "$ylabel" "$c" "$cfg"
      done
    done
  done
  echo "Bildgenerierung abgeschlossen. Zielordner: $output_dir"
fi

# 2. Timing-Messung (still, orbit, simulation)
if [[ "$mode" == "timing" || "$mode" == "all" ]]; then
  echo "Starte Matrix-Timingmessungen (Variante: $variant)..."
  for s in "${seeds[@]}"; do
    if [[ -n "$filter_seed" && "$s" != "$filter_seed" ]]; then continue; fi

    for y in "${years[@]}"; do
      if [[ -n "$filter_year" && "$y" != "$filter_year" ]]; then continue; fi
      ylabel="${year_labels[$y]}"

      for tm in still orbit simulation; do
        run_timing "$s" "$y" "$ylabel" "$tm"
      done
    done
  done
  echo "Timingmessungen abgeschlossen."
fi
