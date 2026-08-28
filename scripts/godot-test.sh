#!/usr/bin/env bash
# Führt EIN Godot-Vertragsskript aus und bewertet SEINE Ausgabe statt des
# Exit-Codes der Engine.
#
#   scripts/godot-test.sh res://tests/water_geometry.gd WATER_GEOMETRY_OK
#
# Warum nicht direkt `"$GODOT" --headless --script …`: Godot 4.7.1 reißt auf dem
# ubuntu-22.04-Runner sporadisch beim HERUNTERFAHREN ab (Signal 11, Exit 139) —
# also NACHDEM das Skript alle Prüfungen bestanden, seine Erfolgsmarke gedruckt
# und quit(0) gerufen hat. Für den Import-Schritt ist das seit Issue #61
# diagnostiziert und dokumentiert (.github/workflows/ci.yml: Abbruch in Thread 1
# IM Godot-Binary, kein Extension-Frame, lokal nicht reproduzierbar); dort fängt
# ihn eine Wiederholung ab. Am 2026-08-27 traf derselbe Absturz erstmals einen
# Vertragstest: Lauf 33123585937 druckte "WATER_GEOMETRY_OK" und starb 1,4 s
# später mit Exit 139, während DERSELBE Commit auf seinem Branch (Lauf
# 33118130758) sauber durchlief.
#
# Der Vertrag ist die Erfolgsmarke, nicht der Exit-Code: jedes Skript unter
# game/tests/ druckt sie als LETZTE Zeile vor `quit(0)` und meldet jeden
# Fehlschlag vorher mit "FAIL: …" und `quit(1)`. Deshalb gilt hier:
#
#   Marke gedruckt → bestanden (bei Exit ≠ 0 zusätzlich eine laute Warnung),
#   Marke fehlt    → rot, mit dem Exit-Code der Engine.
#
# Ein Absturz MITTEN im Test bleibt damit rot, ebenso jedes `quit(1)`; nur das
# Aufräumen NACH dem bestandenen Test darf scheitern. Wiederholen statt werten
# wäre die schwächere Antwort: es würde einen wirklich wackeligen Test verstecken
# und den Lauf um dessen volle Laufzeit verlängern.
#
# Die Marke wird dabei irgendwo in der Ausgabe gesucht, nicht als letzte Zeile:
# nach `quit(0)` schreibt die Engine noch selbst. Damit hinge die Wertung allein
# an der Konvention „Marke erst NACH allen Prüfungen". Deshalb steht davor ein
# zweiter Wächter: meldet das Log irgendwo einen Fehlschlag (`FAIL: …`,
# `FAIL_PHYSICS: …`), ist der Lauf rot, auch wenn die Marke dasteht. Der
# Vergleich ist bewusst ungeankert — die Skripte melden teils mit `print`, teils
# über `push_error`, das Godot mit eigenem Präfix ausgibt.

# Kein `set -e`: der Exit-Code der Engine wird hier ausgewertet, nicht befolgt.
set -uo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
	echo "Aufruf: scripts/godot-test.sh <res://tests/…gd> <ERFOLGSMARKE>" >&2
	exit 2
fi
SKRIPT="$1"
MARKE="$2"

# Version und Pfad NICHT doppeln: scripts/fetch-godot.sh ist die einzige Quelle
# der Godot-Version (CI setzt $GODOT bereits daraus).
GODOT="${GODOT:-$(scripts/fetch-godot.sh --path)}"
if [[ ! -x "$GODOT" ]]; then
	echo "Godot nicht gefunden: $GODOT" >&2
	echo "Holen mit: scripts/fetch-godot.sh   (oder GODOT=/pfad/zu/godot setzen)" >&2
	exit 1
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# tee, damit die Ausgabe im CI-Log live sichtbar bleibt; der Exit-Code kommt aus
# PIPESTATUS, nicht aus tee.
"$GODOT" --headless --path game --script "$SKRIPT" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

if grep -qE "FAIL[_A-Z]*:" "$LOG"; then
	echo "::error::$SKRIPT: Fehlschlag im Log gemeldet (Exit $RC) — der Test ist NICHT bestanden."
	[[ "$RC" -eq 0 ]] && RC=1
	exit "$RC"
fi

if grep -qF -- "$MARKE" "$LOG"; then
	if [[ "$RC" -ne 0 ]]; then
		echo "::warning::$SKRIPT: '$MARKE' gedruckt, Engine danach mit Exit $RC abgebrochen (Issue #61) — als bestanden gewertet."
	fi
	exit 0
fi

echo "::error::$SKRIPT: Erfolgsmarke '$MARKE' fehlt (Exit $RC) — der Test ist NICHT durchgelaufen."
[[ "$RC" -eq 0 ]] && RC=1
exit "$RC"
