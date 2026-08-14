#!/usr/bin/env bash
# Startet die lokal installierte Godot-Version mit dem Projekt.
set -euo pipefail
cd "$(dirname "$0")/.."

# Nicht gegen eine veraltete GDExtension starten: Godot lädt game/bin/ blind und
# meldet fehlende Funktionen erst mitten im Spiel (siehe scripts/build-stamp.sh).
scripts/build-stamp.sh --check

# Version und Pfad NICHT hier doppeln: scripts/fetch-godot.sh ist die einzige
# Quelle der Godot-Version (CI benutzt dasselbe Skript, siehe dort).
GODOT="${GODOT:-$(scripts/fetch-godot.sh --path)}"
if [[ ! -x "$GODOT" ]]; then
	echo "Godot nicht gefunden: $GODOT" >&2
	echo "Holen mit: scripts/fetch-godot.sh   (oder GODOT=/pfad/zu/godot setzen)" >&2
	exit 1
fi

# Die lokale Godot-Installation ergaenzt auf schlanken Debian-Systemen fehlende
# X11-/Wayland-Laufzeitbibliotheken, ohne globale Pakete vorauszusetzen.
LOCAL_LIBS="$PWD/.tools/debian-libs/usr/lib/x86_64-linux-gnu"
if [[ -d "$LOCAL_LIBS" ]]; then
	export LD_LIBRARY_PATH="$LOCAL_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

exec "$GODOT" --path game "$@"
