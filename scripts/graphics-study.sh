#!/usr/bin/env bash
# Reproduzierbare A/B-Studie #116. Aufruf aus beliebigem Verzeichnis.
set -euo pipefail
cd "$(dirname "$0")/.."
variant="${1:-prototype}"
camera="${2:-detail}"
mode="${3:-interactive}"
output="${4:-/tmp/river-sim-study}"
case "$variant" in baseline|prototype) ;; *) echo "Variante: baseline|prototype" >&2; exit 2;; esac
case "$mode" in interactive|shot|still|orbit|simulation) ;; *) echo "Modus: interactive|shot|still|orbit|simulation" >&2; exit 2;; esac
case "$camera" in
overview) export RS_DIST=151.846515 RS_TARGET=0,0 RS_YAW=0.7 RS_PITCH=0.85 ;;
detail) export RS_DIST=42 RS_TARGET=-12,-25 RS_YAW=0.7 RS_PITCH=0.85 ;;
*) echo "Kamera: overview|detail" >&2; exit 2;;
esac
unset RS_SHOT RS_FPS RS_IDLE RS_FLATTEN RS_WATER_STAMP RS_WATER_GPU RS_RENDER_GRID RS_DEBUG_DIFF RS_NO_MEANDER_PAINT RS_DIAG
export RS_SEED=1337 RS_STEP=20000 RS_STEP_CHUNK=1000 RS_QUALITY=balanced
export RS_STUDY_VARIANT="$variant" RS_STUDY_MODE="$mode" RS_STUDY_OUTPUT="$output"
if [[ "$mode" == interactive ]]; then export RS_STUDY_MODE=""; fi
set -- --maximized
if [[ -n "${RS_STUDY_MOVIE:-}" ]]; then
  case "$mode" in orbit|simulation) ;; *) echo "Film braucht orbit oder simulation" >&2; exit 2;; esac
  # MovieWriter öffnet den Encoder vor dem Maximieren. Die Zielauflösung muss
  # deshalb schon beim Engine-Start feststehen, sonst bleibt der Film 1152×648.
  set -- "$@" --resolution 3456x2104 --write-movie "$RS_STUDY_MOVIE" --fixed-fps 30
fi
exec scripts/start.sh "$@" res://studies/flusstal/Flusstal.tscn
