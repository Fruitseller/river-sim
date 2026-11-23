#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP_ROOTS=(Extension/Sources SimCore/Sources)
STAMP_GENERATED_DIR="Extension/Sources/RiverSimGD/Generated"
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

library_stamp() {
	local lib
	lib="$(library_path)"
	[[ -n "$lib" ]] || return 0
	{ grep -ao "$STAMP_MARKER:[0-9a-f]\{64\}" "$lib" 2>/dev/null || true; } |
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
			echo "Godot würde ohne SimNode starten (\"SimNode nicht registriert\")."
		else
			if [[ -z "$have" ]]; then
				echo "FEHLER: $lib enthält keinen Build-Stempel und ist damit älter als diese Prüfung."
			else
				echo "FEHLER: $lib ist VERALTET (Build-Stempel weicht vom Quellstand ab)."
				echo "  Library:    $have"
				echo "  Quellstand: $want"
			fi
			echo "Godot würde still die alte Library laden (z. B. \"Nonexistent function ...\")."
		fi
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
