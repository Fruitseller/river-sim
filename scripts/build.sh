#!/usr/bin/env bash
# Baut die GDExtension und kopiert ihre Laufzeitbibliotheken nach game/bin/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if ! command -v swift >/dev/null 2>&1; then
	SWIFTLY_ENV="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
	if [[ -f "$SWIFTLY_ENV" ]]; then
		# Nicht-interaktive Shells laden die von Swiftly angepasste Profil-Datei nicht.
		. "$SWIFTLY_ENV"
	fi
fi
if ! command -v swift >/dev/null 2>&1; then
	echo "Swift nicht gefunden. Installiere Swift 6 oder richte Swiftly ein." >&2
	exit 1
fi

if [[ "$(uname -s)" == "Linux" ]]; then
	# Swiftlys Ubuntu-Toolchain erwartet libncurses.so.6; Debian stellt nur die
	# binärkompatible Wide-Char-Variante bereit. Die Verknüpfung bleibt lokal.
	COMPAT_LIBS="$PWD/.tools/swift-libs"
	if [[ ! -e "$COMPAT_LIBS/libncurses.so.6" && -e /usr/lib/x86_64-linux-gnu/libncursesw.so.6 ]]; then
		mkdir -p "$COMPAT_LIBS"
		ln -s /usr/lib/x86_64-linux-gnu/libncursesw.so.6 "$COMPAT_LIBS/libncurses.so.6"
	fi
	if [[ -d "$COMPAT_LIBS" ]]; then
		export LD_LIBRARY_PATH="$COMPAT_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	fi
fi

# Build-Stempel des Quellstands in die Library einbrennen: Godot lädt game/bin/
# blind, eine veraltete .so fällt sonst erst als "Nonexistent function ..." auf
# (Verfahren und Prüfung: scripts/build-stamp.sh).
STAMP="$(scripts/build-stamp.sh --source)"
STAMP_FILE="Extension/Sources/RiverSimGD/Generated/BuildStamp.swift"
mkdir -p "$(dirname "$STAMP_FILE")"
STAMP_SOURCE="// GENERIERT von scripts/build.sh — nicht bearbeiten, nicht einchecken.
// Stempel der Quellen unter Extension/Sources und SimCore/Sources; Verfahren und
// Gegenprüfung: scripts/build-stamp.sh, game/scripts/BuildStamp.gd.
enum BuildStamp {
    /// Marker und Hash stehen bewusst in EINEM Literal: so bleibt der Stempel in
    /// der gebauten .so/.dylib greifbar (start.sh liest ihn ohne Godot-Start).
    static let marked = \"RIVERSIM_BUILD_STAMP:$STAMP\"

    /// Reiner Hash — SimNode.buildStamp() reicht ihn an Godot weiter.
    static var value: String { String(marked.split(separator: \":\").last ?? \"\") }
}"
# Nur bei Abweichung schreiben, sonst kompiliert SwiftPM das Modul jedes Mal neu.
if [[ ! -f "$STAMP_FILE" || "$(cat "$STAMP_FILE")" != "$STAMP_SOURCE" ]]; then
	printf '%s\n' "$STAMP_SOURCE" >"$STAMP_FILE"
fi
echo "==> Build-Stempel $STAMP"

echo "==> swift build ($CONFIG)"
# SwiftGodot baut mit library-evolution; die Interface-Verifikation kann dessen
# internes GDExtension-Modul nicht sehen. Swift 5-Sprachmodus hält den 5.9-Code
# mit aktuellen Swift-6-Toolchains kompatibel.
swift build -c "$CONFIG" --package-path Extension \
	-Xswiftc -no-verify-emitted-module-interface \
	-Xswiftc -swift-version -Xswiftc 5 \
	-Xlinker -rpath -Xlinker '$ORIGIN'

mkdir -p game/bin
case "$(uname -s)" in
Darwin)
	BUILD="Extension/.build/$CONFIG"
	cp "$BUILD/libRiverSimGD.dylib" game/bin/libRiverSimGD.dylib
	cp "$BUILD/libSwiftGodot.dylib" game/bin/libSwiftGodot.dylib
	codesign -s - -f game/bin/libSwiftGodot.dylib
	codesign -s - -f game/bin/libRiverSimGD.dylib
	echo "==> macOS-GDExtension gebaut und signiert"
	;;
Linux)
	TARGET_INFO="$(swift -print-target-info)"
	TRIPLE="$(printf '%s' "$TARGET_INFO" | perl -0777 -ne 'print "$1\n" if /"triple":\s*"([^"]+)"/')"
	BUILD="Extension/.build/$TRIPLE/$CONFIG"
	cp "$BUILD/libRiverSimGD.so" game/bin/libRiverSimGD.so
	cp "$BUILD/libSwiftGodot.so" game/bin/libSwiftGodot.so
	# Swift ist auf Linux nicht Teil des Betriebssystems. Die Runtime neben die
	# Extension legen, damit Godot ohne gesetztes LD_LIBRARY_PATH starten kann.
	SWIFT_RUNTIME="$(printf '%s' "$TARGET_INFO" | perl -0777 -ne 'print "$1\n" if /"runtimeLibraryPaths":\s*\[\s*"([^"]+)"/')"
	cp "$SWIFT_RUNTIME"/*.so game/bin/
	echo "==> Linux-GDExtension samt Swift-Runtime gebaut"
	;;
*)
	echo "Nicht unterstuetztes Betriebssystem: $(uname -s)" >&2
	exit 1
	;;
esac

# Gegenprobe: der eingebrannte Stempel muss in der KOPIERTEN Library ankommen —
# sonst wäre die Veraltet-Prüfung von start.sh/smoke.gd wirkungslos.
scripts/build-stamp.sh --check
