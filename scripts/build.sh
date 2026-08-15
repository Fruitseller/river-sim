#!/usr/bin/env bash
# Baut die GDExtension und kopiert ihre Laufzeitbibliotheken nach game/bin/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

# ---------------------------------------------------------------------------
# Toolchain auflösen — außerhalb der normalisierten Umgebung (siehe unten).
# ---------------------------------------------------------------------------
SWIFT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(uname -s)" == "Linux" ]]; then
	# Swiftly stellt Swift auf Linux bereit; sein bin-Verzeichnis kommt VOR die
	# Systempfade, damit der Swiftly-Shim gewinnt.
	SWIFTLY_BIN="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/bin"
	if [[ -x "$SWIFTLY_BIN/swift" ]]; then
		SWIFT_PATH="$SWIFTLY_BIN:$SWIFT_PATH"
	fi

	# Swiftlys Ubuntu-Toolchain erwartet libncurses.so.6; Debian stellt nur die
	# binärkompatible Wide-Char-Variante bereit. Die Verknüpfung bleibt lokal.
	COMPAT_LIBS="$PWD/.tools/swift-libs"
	if [[ ! -e "$COMPAT_LIBS/libncurses.so.6" && -e /usr/lib/x86_64-linux-gnu/libncursesw.so.6 ]]; then
		mkdir -p "$COMPAT_LIBS"
		ln -s /usr/lib/x86_64-linux-gnu/libncursesw.so.6 "$COMPAT_LIBS/libncurses.so.6"
	fi
fi

# Toolchains außerhalb von Swiftly/Xcode (CI installiert die swift.org-Toolchain
# direkt nach /opt/swift, siehe .github/actions/swift-toolchain). Bewusst EINE
# gezielte Variable statt „PATH des Aufrufers durchreichen": die normalisierte
# Umgebung ist der ganze Zweck dieses Skripts — jeder durchgereichte PATH würde
# die Build-Signaturen wieder an den Aufrufer koppeln
# (docs/build-invalidation-measurements.md).
#
# Steht ZULETZT und gewinnt damit auch gegen ein gefundenes Swiftly: eine gezielt
# gesetzte Variable, die eine Autoerkennung still überstimmt, wäre keine.
if [[ -n "${RS_SWIFT_BIN:-}" ]]; then
	SWIFT_PATH="$RS_SWIFT_BIN:$SWIFT_PATH"
fi

# swift build verschlüsselt die KOMPLETTE Prozessumgebung in die Signaturen der
# Plugin- und Tool-Builds: schon EINE geänderte Variable (anderes Terminal-Pane,
# Editor, Agent-Session) baut swift-syntax und die SwiftGodot-Codegen-Tools neu,
# und deren neue mtimes reißen den Codegen + SwiftGodot + RiverSimGD mit —
# real gemessen ~10 min statt No-Op (docs/build-invalidation-measurements.md).
# Deshalb laufen ALLE swift-Aufrufe unter einer festen Minimal-Umgebung; die
# Toolchain wählt allein xcode-select bzw. Swiftly, nicht der PATH des Aufrufers.
# Nur DEVELOPER_DIR wird durchgereicht (bewusste Xcode-Wahl, z. B. Beta).
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

# ---------------------------------------------------------------------------
# Geteilter Build-Cache: Worktrees bauen in das Extension/.build des
# Haupt-Repos. Die Abhängigkeiten (swift-syntax, SwiftGodot samt Codegen)
# haben dort identische Kommando-Signaturen und werden übernommen; nur
# RiverSimGD/SimCore (worktree-eigene Quellpfade) kompilieren neu. Das ersetzt
# die frühere Handarbeit „.build kopieren, ModuleCache löschen".
# RS_NO_SHARED_BUILD=1 erzwingt einen eigenständigen Build im Worktree.
# ---------------------------------------------------------------------------
SCRATCH="$PWD/Extension/.build"
MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
if [[ -z "${RS_NO_SHARED_BUILD:-}" && "$MAIN_ROOT" != "$PWD" && -d "$MAIN_ROOT/Extension" ]]; then
	SCRATCH="$MAIN_ROOT/Extension/.build"
	echo "==> Worktree: geteilter Build-Cache $SCRATCH"
fi

# Ein Build je Scratch: Bereinigung, swift build und Marker sind nicht
# nebenläufigkeitsfest — ein paralleler Worktree-Build könnte sonst mitten im
# Lauf die Planungs-Caches und Artefakte des anderen wegräumen. Der Lock ist
# ein Symlink mit der PID als Ziel: Anlegen ist EIN atomarer Syscall (macOS
# hat kein flock(1)), es gibt kein Fenster zwischen Lock und PID-Ablage. Er
# liegt bewusst außerhalb des Repos (fester Pfad, je Scratch einer), damit
# git clean -fdx ihn nicht einem LAUFENDEN Build unter den Füßen wegzieht.
LOCK="/tmp/riversim-build-$(printf '%s' "$SCRATCH" | cksum | cut -d' ' -f1).lock"
until ln -s "$$" "$LOCK" 2>/dev/null; do
	OTHER="$(readlink "$LOCK" 2>/dev/null || true)"
	# Besitzer-Verifikation über die Kommandozeile statt kill -0: eine an
	# einen fremden Prozess wiedervergebene PID hielte den Lock sonst ewig.
	if [[ -n "$OTHER" ]] && ! ps -p "$OTHER" -o command= 2>/dev/null | grep -q build.sh; then
		# Übernahme per atomarem rename: genau EIN Wartender gewinnt das mv
		# und räumt nur den beiseite geschobenen Link weg — niemand kann den
		# frisch angelegten Lock eines anderen löschen.
		mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -f "$LOCK.stale.$$" || true
		continue
	fi
	echo "==> Scratch belegt (Build-PID ${OTHER:-unbekannt}) — warte …"
	sleep 5
done
trap 'rm -f "$LOCK"' EXIT

# SwiftPM cached die Build-Beschreibung mit ABSOLUTEN Pfaden des zuletzt
# bauenden Checkouts. Beim Wechsel Haupt-Repo ↔ Worktree würde swift build
# sonst still die Quellen des ALTEN Checkouts weiterbenutzen (real passiert;
# der Build-Stempel-Check fing es ab). Deshalb: wechselt der Checkout-Root,
# fliegt der Planungs-Cache raus und SwiftPM plant gegen die frischen
# Manifest-Pfade neu. workspace-state.json bleibt UNBEDINGT stehen — sein
# Löschen checkt die Abhängigkeiten neu aus (frische mtimes) und kostet real
# einen kompletten Neubau (7:25 min gemessen). Die teuren Artefakte
# (build.db-Regelergebnisse, checkouts, kompilierte Module) überleben den
# Wechsel; nur Replan + die checkout-eigenen Module (SimCore, RiverSimGD)
# laufen neu.
ROOT_MARKER="$SCRATCH/riversim-last-root.txt"
if [[ -d "$SCRATCH" && "$(cat "$ROOT_MARKER" 2>/dev/null)" != "$PWD" ]]; then
	rm -f "$SCRATCH"/*.yaml \
		"$SCRATCH"/*/*/description.json "$SCRATCH"/*/*/plugin-tools-description.json
	# Die checkout-eigenen Ausgaben teilen sich zwischen den Roots dieselben
	# Pfade; ein übrig gebliebenes Objekt des anderen Checkouts darf den
	# Link nie überleben (llbuild verwaltet je Root eigene Regeln auf
	# denselben Output-Dateien — das ist beim Wechsel nicht verlässlich).
	rm -rf "$SCRATCH"/*/*/RiverSimGD.build "$SCRATCH"/*/*/SimCore.build \
		"$SCRATCH"/*/*/Modules/RiverSimGD* "$SCRATCH"/*/*/Modules/SimCore* \
		"$SCRATCH"/*/*/libRiverSimGD.*
fi

# Toolchain-Wechsel ist der einzige legitime Grund für einen Voll-Neubau ohne
# Quelländerung — er soll sichtbar sein, statt still 10 Minuten zu kosten.
FPRINT="$(swift_env swift --version 2>/dev/null)"
FPRINT_FILE="$SCRATCH/riversim-toolchain.txt"
if [[ -f "$FPRINT_FILE" ]] && ! diff -q "$FPRINT_FILE" <(printf '%s\n' "$FPRINT") >/dev/null; then
	echo "==> ACHTUNG: Toolchain gewechselt — Voll-Neubau der Abhängigkeiten steht an (~10 min)." >&2
	echo "    vorher:  $(head -1 "$FPRINT_FILE")" >&2
	echo "    nachher: $(printf '%s\n' "$FPRINT" | head -1)" >&2
fi
# Direkt nach dem Vergleich schreiben, nicht erst nach dem Build: ein
# abgebrochener Build würde die Warnung sonst bei jedem Folgelauf wiederholen.
mkdir -p "$SCRATCH" && printf '%s\n' "$FPRINT" >"$FPRINT_FILE"

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
# mit aktuellen Swift-6-Toolchains kompatibel. --product RiverSimGD lässt die
# nicht gebrauchten Begleit-Produkte (SwiftGodot-Testextension, docc-/man-
# Generatoren) aus dem Hauptplan heraus.
# Zweimal bauen: Nach Kaltbau/Neuplanung invalidieren sich Plugin-Tools-Plan
# und Hauptplan (teils dieselben Ausgabepfade) einmal gegenseitig — sonst
# baut erst der NÄCHSTE Aufruf überraschend ~5 min „aus dem Nichts" (real
# gemessen, docs/build-invalidation-measurements.md). Der zweite Durchlauf
# konvergiert das sofort; im Normalfall ist er ein ~0,4-s-No-Op.
for _ in 1 2; do
	swift_env swift build -c "$CONFIG" --package-path Extension \
		--scratch-path "$SCRATCH" \
		--product RiverSimGD \
		-Xswiftc -no-verify-emitted-module-interface \
		-Xswiftc -swift-version -Xswiftc 5 \
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
