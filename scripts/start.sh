#!/usr/bin/env bash
# Startet die lokal installierte Godot-Version mit dem Projekt.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-$PWD/.tools/godot-4.7.1/Godot_v4.7.1-stable_linux.x86_64}"
if [[ ! -x "$GODOT" ]]; then
	echo "Godot nicht gefunden. Setze GODOT oder installiere die lokale Version." >&2
	exit 1
fi

# Die lokale Godot-Installation ergaenzt auf schlanken Debian-Systemen fehlende
# X11-/Wayland-Laufzeitbibliotheken, ohne globale Pakete vorauszusetzen.
LOCAL_LIBS="$PWD/.tools/debian-libs/usr/lib/x86_64-linux-gnu"
if [[ -d "$LOCAL_LIBS" ]]; then
	export LD_LIBRARY_PATH="$LOCAL_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

exec "$GODOT" --path game "$@"
