#!/usr/bin/env bash
# Holt die im Repo festgelegte Godot-Version nach .tools/ und gibt ihren Pfad aus.
#
# Zweck: CI (.github/workflows/ci.yml) und Arbeitsplatz benutzen DIESELBE
# Binärdatei. Die Godot-Version ist Teil des Vertrags, den die Godot-Tests unter
# game/tests/ prüfen — läuft CI gegen eine andere Version als der Entwickler,
# beweist ein grüner Lauf nichts über den lokalen Stand.
#
# Aufrufe:
#   fetch-godot.sh          bei Bedarf herunterladen, Pfad der Binärdatei auf stdout
#   fetch-godot.sh --path   nur den Pfad ausgeben (lädt nichts, prüft nichts)
#
# Fortschritt und Fehler gehen nach stderr, damit `GODOT="$(scripts/fetch-godot.sh)"`
# sauber funktioniert.
set -euo pipefail
cd "$(dirname "$0")/.."

# Einzige Quelle der Godot-Version im Repo (scripts/start.sh liest sie hier über
# `--path`). Beim Anheben: Version UND Prüfsumme zusammen austauschen, danach
# game/tests/ einmal komplett laufen lassen — die Tests pinnen Godot-Verhalten.
GODOT_VERSION="4.7.1"
# sha256 des offiziellen Release-Archivs von github.com/godotengine/godot.
# Ohne Prüfsumme wäre der Download eine ungeprüfte Fremdbinärdatei im CI-Job.
GODOT_SHA256="c7ff14fd28472c8d4f193043de30278dcf7e5241a1dcf7566b02e27addaa33ba"

ARCHIVE="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
DEST=".tools/godot-${GODOT_VERSION}"
BIN="$PWD/$DEST/Godot_v${GODOT_VERSION}-stable_linux.x86_64"

if [[ "${1:-}" == "--path" ]]; then
	printf '%s\n' "$BIN"
	exit 0
fi
if [[ -n "${1:-}" ]]; then
	echo "Unbekannte Option: $1 (erlaubt: --path)" >&2
	exit 2
fi

if [[ -x "$BIN" ]]; then
	printf '%s\n' "$BIN"
	exit 0
fi

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
	echo "Dieses Skript lädt nur die Linux-x86_64-Binärdatei." >&2
	echo "Auf anderen Systemen Godot ${GODOT_VERSION} selbst installieren und GODOT=… setzen." >&2
	exit 1
fi

echo "==> Lade Godot ${GODOT_VERSION} …" >&2
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 \
	"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/${ARCHIVE}" \
	-o "$TMP/$ARCHIVE"

# Prüfsumme VOR dem Entpacken: eine manipulierte oder abgeschnittene Datei darf
# gar nicht erst in .tools/ landen.
echo "${GODOT_SHA256}  $TMP/$ARCHIVE" | sha256sum -c --status || {
	echo "FEHLER: Prüfsumme von $ARCHIVE stimmt nicht." >&2
	echo "  erwartet: $GODOT_SHA256" >&2
	echo "  gelesen:  $(sha256sum "$TMP/$ARCHIVE" | cut -d' ' -f1)" >&2
	exit 1
}

mkdir -p "$DEST"
unzip -q -o "$TMP/$ARCHIVE" -d "$DEST"
chmod +x "$BIN"
echo "==> Godot bereit: $BIN" >&2
printf '%s\n' "$BIN"
