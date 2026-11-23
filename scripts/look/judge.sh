#!/usr/bin/env bash
set -euo pipefail
a=${1:?A-Ordner fehlt}; b=${2:?B-Ordner fehlt}; runs=${3:-10}
root=$(cd "$(dirname "$0")/../.." && pwd)
refs=$root/docs/references/zielbild
work=$(mktemp -d "${TMPDIR:-/tmp}/look-judge.XXXXXX")
meta=$(mktemp -d "${TMPDIR:-/tmp}/look-urteile.XXXXXX")
judges=${LOOK_JUDGES:-deepseek}

shots=(
  "diorama|d-insel-diorama-schoen.jpg|Die Referenz ist hier auch FORMZIEL: Großform der Insel, Kamm, Täler, Küste dürfen mitzählen."
  "tal|e-tal-kueste-schoen.jpg|Die Referenz zeigt hier NUR Material und Licht. Ihre Landformen sind erfunden; vergleiche KEINE Formen, Bildaufbau oder Kamera, nur wie Wasser, Ufer, Strand, Wald, Fels, Schnee, Meer und Licht dargestellt sind."
  "nah|f-nah-flussschleife-schoen.jpg|Die Referenz ist hier Darstellungsziel aus derselben Kamera. Die Flussläufe selbst (Schlingen, Parallel-Arme) zählen NICHT, nur wie sie dargestellt sind."
)

prompt() { cat <<P
Du bewertest Bilder aus einem Landschafts-Simulationsspiel (Vogelperspektive,
Erosion, Flüsse). Bild 1 ist die REFERENZ: ein aufgehübschtes Zielbild.
Bild 2 ist Kandidat X, Bild 3 ist Kandidat Y. Beide sind echte Spielbilder
aus derselben Kamera und derselben Welt; sie unterscheiden sich nur in der
Darstellung.

Frage: Welcher Kandidat kommt der REFERENZ in Bildwirkung und Darstellungs-
qualität näher? Achte vor allem auf:
- Wasser: liegt es als Wasserkörper IM Gelände (Bett, Ufer, Tiefe), oder als
  flaches Band darauf bzw. darüber?
- Wald als glaubwürdige Flächen mit Lichtungen statt gleichförmigem Muster.
- Fels, Hänge und Schnee mit Struktur statt glatter Knete bzw. Zuckerguss.
- Küste, Strand, Flachwasser, Licht und Atmosphäre.
$1
Bewerte nicht Schärfe-Artefakte der Referenz, Wolkenpositionen oder
Kleinigkeiten unter 1 % der Bildfläche. Siehst du keinen klaren, auf den
ersten Blick erkennbaren Unterschied in diesen Punkten, urteile GLEICH.

Antworte mit höchstens drei Sätzen Begründung und als LETZTE Zeile genau
eine dieser Zeilen:
URTEIL: X
URTEIL: Y
URTEIL: GLEICH
P
}

judge_one() {
  local d; d=$(mktemp -d "$work/j.XXXXXX")
  cp "$2" "$d/ref.jpg"; cp "$3" "$d/x.jpg"; cp "$4" "$d/y.jpg"
  set -- "$1" "$d/ref.jpg" "$d/x.jpg" "$d/y.jpg" "$5" "$6"
  case $1 in
    deepseek) (cd "$d" && opencode run --archived \
             -m "sipgate/deepseek-ai/DeepSeek-V4.1-Flash-1017#high" \
             -f "$2" -f "$3" -f "$4" "$(cat "$6")" >"$5" 2>&1) ;;
    codex) codex exec --skip-git-repo-check --ephemeral -s read-only \
             -i "$2" -i "$3" -i "$4" -o "$5" - <"$6" >/dev/null 2>&1 ;;
    codex-high) codex exec --skip-git-repo-check --ephemeral -s read-only \
             -c model_reasoning_effort=high \
             -i "$2" -i "$3" -i "$4" -o "$5" - <"$6" >/dev/null 2>&1 ;;
    *) echo "unbekannter Bewerter $1" >&2; return 1 ;;
  esac
}

jobs_=()
for s in "${shots[@]}"; do
  IFS='|' read -r name ref extra <<<"$s"
  prompt "$extra" >"$meta/$name.prompt"
  for j in $judges; do
    for r in $(seq 1 "$runs"); do
      if (( RANDOM % 2 )); then x=$a; y=$b; xa=X; else x=$b; y=$a; xa=Y; fi
      tag=$name.$j.$r
      echo "$xa" >"$meta/$tag.a_is"
      judge_one "$j" "$refs/$ref" "$x/$name.jpg" "$y/$name.jpg" \
        "$meta/$tag.out" "$meta/$name.prompt" &
      jobs_+=($!)
    done
  done
done
for p in "${jobs_[@]}"; do wait "$p" || true; done

aw=0; bw=0; tie=0; total=0
for f in "$meta"/*.out; do
  tag=$(basename "$f" .out)
  v=$(sed $'s/\x1b\\[[0-9;]*m//g' "$f" | grep -E '^[[:space:]]*URTEIL:' | tail -1 \
      | sed -nE 's/^[[:space:]]*URTEIL:[[:space:]]*(X|Y|GLEICH)[[:space:]]*$/\1/p' || true)
  [[ -n $v ]] || { echo "$tag: kein Urteil"; continue; }
  total=$((total + 1))
  if [[ $v == GLEICH ]]; then w=GLEICH; tie=$((tie + 1))
  elif [[ $v == "$(cat "$meta/$tag.a_is")" ]]; then w=A; aw=$((aw + 1))
  else w=B; bw=$((bw + 1)); fi
  echo "$tag: $w — $(grep -v 'URTEIL' "$f" | tr '\n' ' ' | cut -c1-240)"
done >"$meta/zeilen.txt"
cat "$meta/zeilen.txt"
cam_ok=1
for s in "${shots[@]}"; do
  name=${s%%|*}
  ca=$(grep -cE "^$name\\.[^:]*: A " "$meta/zeilen.txt" || true)
  cb=$(grep -cE "^$name\\.[^:]*: B " "$meta/zeilen.txt" || true)
  echo "AUFNAHME $name A $ca B $cb"
  (( ca > cb )) && cam_ok=0
done
echo "ERGEBNIS A $aw B $bw GLEICH $tie VON $total (Rohurteile: $meta)"
erwartet=$(( ${#shots[@]} * runs * $(wc -w <<<"$judges") ))
if (( total != erwartet )); then
  echo "ENTSCHEIDUNG UNVOLLSTAENDIG ($total von $erwartet Urteilen; nicht behalten, neu fahren)"
  exit 2
fi
if (( total > 0 && 3 * (bw - aw) >= total && 5 * aw <= total && cam_ok )); then
  echo "ENTSCHEIDUNG B_BEHALTEN"
else
  echo "ENTSCHEIDUNG VERWERFEN"
fi
