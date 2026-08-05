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
