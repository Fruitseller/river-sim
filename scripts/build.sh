#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

SWIFT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(uname -s)" == "Linux" ]]; then
	SWIFTLY_BIN="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/bin"
	if [[ -x "$SWIFTLY_BIN/swift" ]]; then
		SWIFT_PATH="$SWIFTLY_BIN:$SWIFT_PATH"
	fi

	COMPAT_LIBS="$PWD/.tools/swift-libs"
	if [[ ! -e "$COMPAT_LIBS/libncurses.so.6" && -e /usr/lib/x86_64-linux-gnu/libncursesw.so.6 ]]; then
		mkdir -p "$COMPAT_LIBS"
		ln -s /usr/lib/x86_64-linux-gnu/libncursesw.so.6 "$COMPAT_LIBS/libncurses.so.6"
	fi
fi

if [[ -n "${RS_SWIFT_BIN:-}" ]]; then
	SWIFT_PATH="$RS_SWIFT_BIN:$SWIFT_PATH"
fi

SWIFT_ENV=(HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" TERM=dumb PATH="$SWIFT_PATH")
[[ -n "${DEVELOPER_DIR:-}" ]] && SWIFT_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
[[ -n "${SWIFTLY_HOME_DIR:-}" ]] && SWIFT_ENV+=(SWIFTLY_HOME_DIR="$SWIFTLY_HOME_DIR")
[[ -n "${COMPAT_LIBS:-}" ]] && SWIFT_ENV+=(LD_LIBRARY_PATH="$COMPAT_LIBS")
swift_env() {
	env -i "${SWIFT_ENV[@]}" "$@"
}

if ! swift_env swift --version >/dev/null 2>&1; then
	echo "Swift nicht gefunden. Installiere Swift 6 oder richte Swiftly ein." >&2
	exit 1
fi

SCRATCH="$PWD/Extension/.build"
MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
if [[ -z "${RS_NO_SHARED_BUILD:-}" && "$MAIN_ROOT" != "$PWD" && -d "$MAIN_ROOT/Extension" ]]; then
	SCRATCH="$MAIN_ROOT/Extension/.build"
	echo "==> Worktree: geteilter Build-Cache $SCRATCH"
fi

LOCK="/tmp/riversim-build-$(printf '%s' "$SCRATCH" | cksum | cut -d' ' -f1).lock"
until ln -s "$$" "$LOCK" 2>/dev/null; do
	OTHER="$(readlink "$LOCK" 2>/dev/null || true)"
	if [[ -n "$OTHER" ]] && ! ps -p "$OTHER" -o command= 2>/dev/null | grep -q build.sh; then
		mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -f "$LOCK.stale.$$" || true
		continue
	fi
	echo "==> Scratch belegt (Build-PID ${OTHER:-unbekannt}) — warte …"
	sleep 5
done
trap 'rm -f "$LOCK"' EXIT

ROOT_MARKER="$SCRATCH/riversim-last-root.txt"
if [[ -d "$SCRATCH" && "$(cat "$ROOT_MARKER" 2>/dev/null)" != "$PWD" ]]; then
	rm -f "$SCRATCH"/*.yaml \
		"$SCRATCH"/*/*/description.json "$SCRATCH"/*/*/plugin-tools-description.json
	rm -rf "$SCRATCH"/*/*/RiverSimGD.build "$SCRATCH"/*/*/SimCore.build \
		"$SCRATCH"/*/*/Modules/RiverSimGD* "$SCRATCH"/*/*/Modules/SimCore* \
		"$SCRATCH"/*/*/libRiverSimGD.*
fi

FPRINT="$(swift_env swift --version 2>/dev/null)"
FPRINT_FILE="$SCRATCH/riversim-toolchain.txt"
if [[ -f "$FPRINT_FILE" ]] && ! diff -q "$FPRINT_FILE" <(printf '%s\n' "$FPRINT") >/dev/null; then
	echo "==> ACHTUNG: Toolchain gewechselt — Voll-Neubau der Abhängigkeiten steht an (~10 min)." >&2
	echo "    vorher:  $(head -1 "$FPRINT_FILE")" >&2
	echo "    nachher: $(printf '%s\n' "$FPRINT" | head -1)" >&2
fi
mkdir -p "$SCRATCH" && printf '%s\n' "$FPRINT" >"$FPRINT_FILE"

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
if [[ ! -f "$STAMP_FILE" || "$(cat "$STAMP_FILE")" != "$STAMP_SOURCE" ]]; then
	printf '%s\n' "$STAMP_SOURCE" >"$STAMP_FILE"
fi
echo "==> Build-Stempel $STAMP"

echo "==> swift build ($CONFIG)"
for _ in 1 2; do
	swift_env swift build -c "$CONFIG" --package-path Extension \
		--scratch-path "$SCRATCH" \
		--product RiverSimGD \
		-Xswiftc -no-verify-emitted-module-interface \
		-Xlinker -rpath -Xlinker '$ORIGIN'
done

printf '%s\n' "$PWD" >"$ROOT_MARKER"

mkdir -p game/bin
case "$(uname -s)" in
Darwin)
	BUILD="$SCRATCH/$CONFIG"
	cp "$BUILD/libRiverSimGD.dylib" game/bin/libRiverSimGD.dylib
	cp "$BUILD/libSwiftGodot.dylib" game/bin/libSwiftGodot.dylib
	codesign -s - -f game/bin/libSwiftGodot.dylib
	codesign -s - -f game/bin/libRiverSimGD.dylib
	echo "==> macOS-GDExtension gebaut und signiert"
	;;
Linux)
	TARGET_INFO="$(swift_env swift -print-target-info)"
	TRIPLE="$(printf '%s' "$TARGET_INFO" | perl -0777 -ne 'print "$1\n" if /"triple":\s*"([^"]+)"/')"
	BUILD="$SCRATCH/$TRIPLE/$CONFIG"
	cp "$BUILD/libRiverSimGD.so" game/bin/libRiverSimGD.so
	cp "$BUILD/libSwiftGodot.so" game/bin/libSwiftGodot.so
	SWIFT_RUNTIME="$(printf '%s' "$TARGET_INFO" | perl -0777 -ne 'print "$1\n" if /"runtimeLibraryPaths":\s*\[\s*"([^"]+)"/')"
	cp "$SWIFT_RUNTIME"/*.so game/bin/
	echo "==> Linux-GDExtension samt Swift-Runtime gebaut"
	;;
*)
	echo "Nicht unterstuetztes Betriebssystem: $(uname -s)" >&2
	exit 1
	;;
esac

scripts/build-stamp.sh --check
