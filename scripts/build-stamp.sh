#!/usr/bin/env bash
# Build-Stempel der GDExtension: berechnet ihn aus dem Quellstand, liest ihn aus
# der gebauten Library und vergleicht beides.
#
# Zweck: Godot lädt die Library aus game/bin/ und merkt NICHT, wenn sie älter ist
# als der Quellstand — der Smoke-Test scheiterte real mit "Nonexistent function
# brush", weil die .so vor dem brush-Commit gebaut war. scripts/build.sh brennt den
# Stempel in die Library ein (Generated/BuildStamp.swift), scripts/start.sh und
# game/tests/smoke.gd brechen bei Abweichung mit dem Rebuild-Befehl ab.
#
# Aufrufe:
#   build-stamp.sh             Stempel des Arbeitsverzeichnisses (nur Hash, stdout)
#   build-stamp.sh --library   in game/bin/libRiverSimGD.* eingebrannter Stempel
#   build-stamp.sh --check     beide vergleichen; Exit 1 + Meldung bei Abweichung
#
# Verfahren (muss mit game/scripts/BuildStamp.gd BYTEGLEICH übereinstimmen):
#   1. Alle regulären Dateien unter Extension/Sources und SimCore/Sources sammeln,
#      außer dem generierten Stempel selbst (sonst hängt der Hash von sich ab).
#   2. Pfade relativ zur Repo-Wurzel, in Byte-Reihenfolge sortiert (LC_ALL=C).
#   3. Manifest-Zeile je Datei: "<sha256>  <relpfad>\n" (zwei Leerzeichen, wie sha256sum).
#   4. Stempel = sha256 des Manifests.
# Nur Inhalt und Pfad zählen, nicht die mtime — ein `touch` ohne inhaltliche
# Änderung löst also keinen falschen Alarm aus, ein `git checkout` eines anderen
# Stands sehr wohl.
set -euo pipefail
cd "$(dirname "$0")/.."

# Verzeichnisse, deren Inhalt in die Library kompiliert wird.
STAMP_ROOTS=(Extension/Sources SimCore/Sources)
# Der generierte Stempel selbst ist ausgenommen (siehe Punkt 1).
STAMP_GENERATED_DIR="Extension/Sources/RiverSimGD/Generated"
# Marker + Hash stehen in der generierten Swift-Datei in EINEM String-Literal und
# landen damit lesbar in der .so/.dylib — so ist der eingebrannte Stempel ohne
# Godot-Start greifbar.
STAMP_MARKER="RIVERSIM_BUILD_STAMP"
REBUILD_HINT='"$(git rev-parse --show-toplevel)"/scripts/build.sh release'

source_stamp() {
	find "${STAMP_ROOTS[@]}" -type f -not -path "$STAMP_GENERATED_DIR/*" -print |
		LC_ALL=C sort |
		while IFS= read -r file; do
			printf '%s  %s\n' "$(sha256sum "$file" | cut -d' ' -f1)" "$file"
		done |
		sha256sum | cut -d' ' -f1
}

# Pfad der gebauten Extension-Library, oder leer wenn keine da ist.
library_path() {
	local candidate
	for candidate in game/bin/libRiverSimGD.so game/bin/libRiverSimGD.dylib; do
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 0
}

# Eingebrannten Stempel aus der Library lesen. Leere Ausgabe = kein Stempel drin
# (Library fehlt oder wurde vor dieser Prüfung gebaut) — für den Aufrufer
# gleichbedeutend mit "veraltet".
library_stamp() {
	local lib
	lib="$(library_path)"
	[[ -n "$lib" ]] || return 0
	# -a: die Library ist binär; grep soll sie trotzdem als Text durchsuchen.
	grep -ao "$STAMP_MARKER:[0-9a-f]\{64\}" "$lib" 2>/dev/null |
		cut -d: -f2 | LC_ALL=C sort -u | head -1
}

case "${1:---source}" in
--source)
	source_stamp
	;;
--library)
	library_stamp
	;;
--check)
	want="$(source_stamp)"
	have="$(library_stamp)"
	if [[ "$want" == "$have" ]]; then
		exit 0
	fi
	lib="$(library_path)"
	{
		if [[ -z "$lib" ]]; then
			echo "FEHLER: game/bin/libRiverSimGD.so fehlt — die GDExtension wurde nie gebaut."
		elif [[ -z "$have" ]]; then
			echo "FEHLER: $lib enthält keinen Build-Stempel und ist damit älter als diese Prüfung."
		else
			echo "FEHLER: $lib ist VERALTET (Build-Stempel weicht vom Quellstand ab)."
			echo "  Library:    $have"
			echo "  Quellstand: $want"
		fi
		echo "Godot würde still die alte Library laden (z. B. \"Nonexistent function ...\")."
		echo "Neu bauen (Linux ~21,5 min):"
		echo "  $REBUILD_HINT"
	} >&2
	exit 1
	;;
*)
	echo "Unbekannte Option: $1 (erlaubt: --source, --library, --check)" >&2
	exit 2
	;;
esac
