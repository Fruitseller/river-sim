#!/usr/bin/env bash
# Blinder Paarvergleich zweier Aufnahme-Sätze gegen die Referenzen.
#
#   scripts/look/judge.sh <A-ordner> <B-ordner> [läufe je aufnahme, Standard 3]
#
# Je Aufnahme und Lauf bekommt der Bewerter (Standard: DeepSeek V4.1 Flash
# über opencode, kostenlos; s. judge_one) Referenz, X und Y; welcher Satz X ist, wird je Lauf
# zufällig gewürfelt. Ausgabe: je Urteil eine Zeile, am Ende
# `ERGEBNIS A <a> B <b> GLEICH <g> VON <n>` und `ENTSCHEIDUNG B_BEHALTEN`
# bzw. `ENTSCHEIDUNG VERWERFEN`.
#
# Entscheidungsregel (seit 2026-11-20, s. docs/look-hillclimb.md § Regel):
# B (der neue Stand) wird behalten, wenn B − A mindestens 1/3 aller Urteile
# beträgt, A höchstens 1/5 der Urteile gewinnt UND in keiner Aufnahme mehr
# A- als B-Stimmen stehen. Gewertet wird über 10 Läufe je Aufnahme (zwei
# Durchgänge mit je 5 oder einer mit 10). „GLEICH“ ist erlaubt und zählt
# nicht gegen B: mit erzwungener Wahl ging dasselbe Bild zweimal gerendert
# (nur Subpixel-Unterschiede) gemessen 6:3 aus. Die frühere Regel (B ≥ 2/3,
# A ≤ 1/9) verwarf gemessen auch kleine echte Verbesserungen.
# Weitere Bewerter (Panel): LOOK_JUDGES="deepseek codex", s. judge_one.
# GLM 5.3 sieht keine Bilder und taugt deshalb nicht als Bewerter.
set -euo pipefail
a=${1:?A-Ordner fehlt}; b=${2:?B-Ordner fehlt}; runs=${3:-3}
root=$(cd "$(dirname "$0")/../.." && pwd)
refs=$root/docs/references/zielbild
work=$(mktemp -d "${TMPDIR:-/tmp}/look-judge.XXXXXX")
meta=$(mktemp -d "${TMPDIR:-/tmp}/look-urteile.XXXXXX")
judges=${LOOK_JUDGES:-deepseek}

# name | Referenz | Zusatz für den Bewerter
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

# Der Bewerter ist ein Agent mit Shell: Er hat gemessen Verzeichnisse
# gelistet und die Aufnahmen unter ihrem echten Pfad (…/base/…, …/it02/…)
# geöffnet, der Vergleich war dann nicht blind. Deshalb bekommt jedes Urteil
# einen eigenen Ordner mit neutralen Kopien (ref/x/y.jpg); die Zuordnung
# (.a_is) und die Ausgaben liegen außerhalb davon in $meta.
judge_one() { # judge ref x y outfile promptfile
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
  v=$(grep -oE 'URTEIL: *(X|Y|GLEICH)' "$f" | tail -1 | sed 's/URTEIL: *//' || true)
  [[ -n $v ]] || { echo "$tag: kein Urteil"; continue; }
  total=$((total + 1))
  if [[ $v == GLEICH ]]; then w=GLEICH; tie=$((tie + 1))
  elif [[ $v == "$(cat "$meta/$tag.a_is")" ]]; then w=A; aw=$((aw + 1))
  else w=B; bw=$((bw + 1)); fi
  echo "$tag: $w — $(grep -v 'URTEIL' "$f" | tr '\n' ' ' | cut -c1-240)"
done >"$meta/zeilen.txt"
cat "$meta/zeilen.txt"
# Je Aufnahme: keine darf mehr A- als B-Stimmen tragen.
cam_ok=1
for s in "${shots[@]}"; do
  name=${s%%|*}
  ca=$(grep -cE "^$name\\.[^:]*: A " "$meta/zeilen.txt" || true)
  cb=$(grep -cE "^$name\\.[^:]*: B " "$meta/zeilen.txt" || true)
  echo "AUFNAHME $name A $ca B $cb"
  (( ca > cb )) && cam_ok=0
done
echo "ERGEBNIS A $aw B $bw GLEICH $tie VON $total (Rohurteile: $meta)"
if (( total > 0 && 3 * (bw - aw) >= total && 5 * aw <= total && cam_ok )); then
  echo "ENTSCHEIDUNG B_BEHALTEN"
else
  echo "ENTSCHEIDUNG VERWERFEN"
fi
