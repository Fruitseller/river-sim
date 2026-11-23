#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT_VERSION="4.7.2"
GODOT_SHA256="cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4"
GODOT_BIN_SHA256="8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e"

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

echo "${GODOT_SHA256}  $TMP/$ARCHIVE" | sha256sum -c --status || {
	echo "FEHLER: Prüfsumme von $ARCHIVE stimmt nicht." >&2
	echo "  erwartet: $GODOT_SHA256" >&2
	echo "  gelesen:  $(sha256sum "$TMP/$ARCHIVE" | cut -d' ' -f1)" >&2
	exit 1
}

mkdir -p "$DEST"
unzip -q -o "$TMP/$ARCHIVE" -d "$DEST"
chmod +x "$BIN"
verify_binary
echo "==> Godot bereit: $BIN" >&2
printf '%s\n' "$BIN"
