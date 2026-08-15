#!/usr/bin/env bash
# Holt die im Repo festgelegte Godot-Version nach .tools/ und gibt ihren Pfad aus.
#
# Zweck: CI (.github/workflows/ci.yml) und Arbeitsplatz benutzen DIESELBE
# Binärdatei. Die Godot-Version ist Teil des Vertrags, den die Godot-Tests unter
# game/tests/ prüfen — läuft CI gegen eine andere Version als der Entwickler,
# beweist ein grüner Lauf nichts über den lokalen Stand.
#
# Aufrufe:
#   fetch-godot.sh          bei Bedarf herunterladen, Prüfsumme verifizieren (auch
#                           bei bereits vorhandener Datei), Pfad auf stdout
#   fetch-godot.sh --path   nur den Pfad ausgeben (lädt nichts, prüft nichts)
#
# Fortschritt und Fehler gehen nach stderr, damit `GODOT="$(scripts/fetch-godot.sh)"`
# sauber funktioniert.
set -euo pipefail
cd "$(dirname "$0")/.."

# Einzige Quelle der Godot-Version im Repo (scripts/start.sh liest sie hier über
# `--path`). Beim Anheben: Version UND BEIDE Prüfsummen zusammen austauschen, danach
# game/tests/ einmal komplett laufen lassen — die Tests pinnen Godot-Verhalten.
GODOT_VERSION="4.7.1"
# sha256 des offiziellen Release-Archivs von github.com/godotengine/godot.
# Ohne Prüfsumme wäre der Download eine ungeprüfte Fremdbinärdatei im CI-Job.
GODOT_SHA256="c7ff14fd28472c8d4f193043de30278dcf7e5241a1dcf7566b02e27addaa33ba"
# sha256 der ENTPACKTEN Binärdatei (aus dem oben geprüften Archiv abgeleitet).
# Nötig, weil der Archiv-Hash nur den Download absichert: liegt die Binärdatei
# schon in .tools/ — im CI-Job der Normalfall, dort füllt actions/cache das
# Verzeichnis, und der Cache-Key hängt nur am Versions-Tag —, wird gar nichts
# heruntergeladen. Ohne diesen zweiten Hash liefen die Vertragstests dann still
# gegen eine veraltete oder untergeschobene Binärdatei. Kostet ~0,1 s.
GODOT_BIN_SHA256="32f8d7596c4b41185512b1c49d69f2da3be018fd784a53e349fa92a98a97bcde"

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

verify_binary() {
	echo "${GODOT_BIN_SHA256}  $BIN" | sha256sum -c --status && return 0
	echo "FEHLER: $BIN hat nicht die erwartete Prüfsumme." >&2
	echo "  erwartet: $GODOT_BIN_SHA256" >&2
	echo "  gelesen:  $(sha256sum "$BIN" | cut -d' ' -f1)" >&2
	echo "  Entweder ist die Datei beschädigt/fremd, oder GODOT_VERSION wurde" >&2
	echo "  ohne die zugehörigen Prüfsummen angehoben. Zum Neuladen:" >&2
	echo "    rm -rf $DEST" >&2
	exit 1
}

# Vorhandene Binärdatei: erst prüfen, dann herausgeben. Absichtlich KEIN stiller
# Neu-Download bei Abweichung — ein untergeschobener Cache-Eintrag soll den Lauf
# rot machen und nicht heimlich repariert werden.
if [[ -x "$BIN" ]]; then
	verify_binary
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
# Hält GODOT_BIN_SHA256 ehrlich: der Hash der entpackten Datei wird auf demselben
# Weg geprüft, auf dem er später den Cache-Restore prüft.
verify_binary
echo "==> Godot bereit: $BIN" >&2
printf '%s\n' "$BIN"
