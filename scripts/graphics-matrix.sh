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
filter_yaws="${RS_MATRIX_YAWS:-}"
dry_run="${RS_MATRIX_DRY_RUN:-0}"
# Qualitätsstufe der Messläufe (#151 misst je Stufe); Aufnahmen bleiben balanced.
quality="${RS_MATRIX_QUALITY:-balanced}"

# Matrix-Definition. Ohne assoziative Arrays: macOS liefert bash 3.2 (die
# Zielmaschine ist ein Mac), `declare -A` brach dort mit Syntaxfehler ab.
seeds=(1337 42 20)
seed_name() {
  case "$1" in
    1337) echo "Flusstal Soča" ;;
    42) echo "Seen- und Beckenplateau" ;;
    20) echo "Hochalpines Massiv" ;;
  esac
}

years=(0 20000 100000)
year_label() {
  case "$1" in
    0) echo "0k" ;;
    20000) echo "20k" ;;
    100000) echo "100k" ;;
  esac
}

# Kameras je Seed: "ziel;distanz;yaw;pitch". Die Sonne ist seit #151 eine feste
# Welt-Sonne (game/scripts/Lighting.gd, Azimut -50°); `backlight` blickt mit
# Yaw = Azimut + 180° (130° = 2.269 rad) genau gegen sie. Spiegel der Tabelle:
# SimCoreTests/GraphicsMatrixTests.swift.
camera_cfg() {
  case "$1:$2" in
    1337:overview|42:overview|20:overview) echo "0,0;151.846515;0.7;0.85" ;;
    1337:detail)    echo "-12,-25;42.0;0.7;0.85" ;;
    1337:grazing)   echo "-10,-20;38.0;0.7;1.35" ;;
    1337:backlight) echo "-12,-25;45.0;2.269;0.85" ;;
    1337:coast)     echo "-36,-32;45.0;0.9;0.85" ;;
    1337:snow)      echo "18,14;48.0;0.6;0.75" ;;
    42:detail)      echo "4,-6;45.0;0.5;0.80" ;;
    42:grazing)     echo "6,-4;40.0;0.4;1.35" ;;
    42:backlight)   echo "4,-6;48.0;2.269;0.85" ;;
    42:coast)       echo "12,-10;38.0;1.1;0.85" ;;
    42:snow)        echo "-22,20;50.0;0.7;0.75" ;;
    20:detail)      echo "-8,10;42.0;0.6;0.80" ;;
    20:grazing)     echo "-6,12;38.0;0.5;1.35" ;;
    20:backlight)   echo "-8,10;46.0;2.269;0.85" ;;
    20:coast)       echo "30,-28;48.0;0.8;0.85" ;;
    20:snow)        echo "-10,14;40.0;0.6;0.70" ;;
  esac
}

camera_order=(overview detail grazing backlight coast snow)

if [[ "$mode" == "list" ]]; then
  echo "Abnahmematrix (Landschaftsqualität #150):"
  echo "Variante: $variant"
  echo "Ausgabepfad: $output_dir"
  for s in "${seeds[@]}"; do
    echo "--- Seed $s ($(seed_name "$s")) ---"
    for y in "${years[@]}"; do
      ylabel="$(year_label "$y")"
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
  local s="$1" y="$2" ylabel="$3" c="$4" cfg="$5" matrix_yaw="${6:-}"
  local target dist yaw pitch
  IFS=';' read -r target dist yaw pitch <<< "$cfg"

  local out_base="$output_dir/seed${s}_${ylabel}_${c}"
  # Blickrichtungs-Serie (#151): RS_MATRIX_YAWS="0.7,2.27,…" rendert dieselbe
  # Kamera aus mehreren Richtungen, Dateiname mit Yaw-Suffix.
  if [[ -n "$matrix_yaw" ]]; then
    yaw="$matrix_yaw"
    out_base="${out_base}_yaw${yaw}"
  fi
  echo "==> [SHOT] Seed $s ($(seed_name "$s")) | Jahr $y ($ylabel) | Kamera $c"
  echo "    Ziel: $target | Dist: $dist | Yaw: $yaw | Pitch: $pitch | Aus: ${out_base}.png"

  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  unset RS_SHOT RS_FPS RS_IDLE RS_FLATTEN RS_WATER_STAMP RS_WATER_GPU RS_RENDER_GRID RS_DEBUG_DIFF RS_NO_MEANDER_PAINT RS_DIAG \
        RS_STUDY_GRID RS_STUDY_LEVERS RS_STUDY_RELIEF RS_STUDY_DEBUG RS_STUDY_MOVIE
  export RS_SEED="$s" RS_STEP="$y" RS_STEP_CHUNK=1000 RS_QUALITY=balanced
  export RS_TARGET="$target" RS_DIST="$dist" RS_YAW="$yaw" RS_PITCH="$pitch"
  export RS_STUDY_VARIANT="$variant" RS_STUDY_MODE="shot" RS_STUDY_OUTPUT="$out_base"

  # Gewertet wird das Bild, nicht der Exit-Code (Absturz beim Herunterfahren,
  # Issue #61); sonst bräche ein Abschluss-Absturz die restliche Matrix ab.
  rm -f "${out_base}.png"
  { scripts/start.sh --maximized res://studies/flusstal/Flusstal.tscn || true; }
  if [[ ! -s "${out_base}.png" ]]; then
    echo "Keine Aufnahme ${out_base}.png" >&2
    exit 1
  fi
}

run_timing() {
  local s="$1" y="$2" ylabel="$3" timing_mode="$4"
  # Timing-Messung auf der Hauptansicht `detail`, mit RS_MATRIX_CAMERA auf
  # einer anderen Kamera der Tabelle.
  local cfg
  cfg="$(camera_cfg "$s" "${filter_camera:-detail}")"
  local target dist yaw pitch
  IFS=';' read -r target dist yaw pitch <<< "$cfg"

  echo "==> [TIMING:$timing_mode] Seed $s ($(seed_name "$s")) | Jahr $y ($ylabel) | Kamera ${filter_camera:-detail}"

  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  unset RS_SHOT RS_FPS RS_IDLE RS_FLATTEN RS_WATER_STAMP RS_WATER_GPU RS_RENDER_GRID RS_DEBUG_DIFF RS_NO_MEANDER_PAINT RS_DIAG \
        RS_STUDY_GRID RS_STUDY_LEVERS RS_STUDY_RELIEF RS_STUDY_DEBUG RS_STUDY_MOVIE
  export RS_SEED="$s" RS_STEP="$y" RS_STEP_CHUNK=1000 RS_QUALITY="$quality"
  export RS_TARGET="$target" RS_DIST="$dist" RS_YAW="$yaw" RS_PITCH="$pitch"
  export RS_STUDY_VARIANT="$variant" RS_STUDY_MODE="$timing_mode" RS_STUDY_OUTPUT=""

  # Ergebnis als Datei neben den Aufnahmen (Spec #156): eine JSON-Zeile je Lauf
  # mit Viewport, Qualitätsstufe und Render-Gitter; der Dateiname trägt Welt,
  # Stadium, Kamera, Stufe und Betrieb. Die Konsolenausgabe bleibt sichtbar.
  # Gewertet wird die Zeile, nicht der Exit-Code: Godot reißt beim
  # Herunterfahren sporadisch ab (Issue #61), die Messung steht dann schon da.
  local out="$output_dir/timing/seed${s}_${ylabel}_${filter_camera:-detail}_${quality}_${timing_mode}.json"
  mkdir -p "$output_dir/timing"
  { scripts/start.sh --maximized res://studies/flusstal/Flusstal.tscn || true; } | tee /dev/stderr \
    | { grep '^STUDY_TIMING ' || true; } | sed 's/^STUDY_TIMING //' > "$out"
  if [[ ! -s "$out" ]]; then
    echo "Keine STUDY_TIMING-Zeile für $out" >&2
    rm -f "$out"
    exit 1
  fi
  echo "    Messung: $out"
}

# 1. Bilderzeugung (shot)
if [[ "$mode" == "shot" || "$mode" == "all" ]]; then
  echo "Starte Matrix-Bildgenerierung (Variante: $variant)..."
  for s in "${seeds[@]}"; do
    if [[ -n "$filter_seed" && "$s" != "$filter_seed" ]]; then continue; fi

    for y in "${years[@]}"; do
      if [[ -n "$filter_year" && "$y" != "$filter_year" ]]; then continue; fi
      ylabel="$(year_label "$y")"

      for c in "${camera_order[@]}"; do
        if [[ -n "$filter_camera" && "$c" != "$filter_camera" ]]; then continue; fi

        cfg="$(camera_cfg "$s" "$c")"
        if [[ -n "$filter_yaws" ]]; then
          IFS=',' read -r -a yaw_list <<< "$filter_yaws"
          for yaw_override in "${yaw_list[@]}"; do
            run_shot "$s" "$y" "$ylabel" "$c" "$cfg" "$yaw_override"
          done
        else
          run_shot "$s" "$y" "$ylabel" "$c" "$cfg"
        fi
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
      ylabel="$(year_label "$y")"

      for tm in still orbit simulation; do
        run_timing "$s" "$y" "$ylabel" "$tm"
      done
    done
  done
  echo "Timingmessungen abgeschlossen."
fi
