#!/usr/bin/env bash
# Baut die GDExtension, kopiert die .dylib nach game/bin/ und signiert sie ad-hoc
# (codesign -s -), damit Gatekeeper sie ohne manuellen Klick lädt.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "==> swift build ($CONFIG)"
# -no-verify-emitted-module-interface: SwiftGodot baut mit library-evolution und
# emittiert ein .swiftinterface, dessen Verifikation das interne GDExtension-Modul
# nicht sieht. Für eine Leaf-GDExtension ist die Verifikation unnötig.
swift build -c "$CONFIG" --package-path Extension \
	-Xswiftc -no-verify-emitted-module-interface

BUILD="Extension/.build/$CONFIG"
mkdir -p game/bin
# Beide dylibs mitnehmen: libRiverSimGD referenziert libSwiftGodot per @rpath und
# hat @loader_path im rpath → die SwiftGodot-Lib muss daneben liegen.
cp "$BUILD/libRiverSimGD.dylib" game/bin/libRiverSimGD.dylib
cp "$BUILD/libSwiftGodot.dylib" game/bin/libSwiftGodot.dylib
codesign -s - -f game/bin/libSwiftGodot.dylib
codesign -s - -f game/bin/libRiverSimGD.dylib
echo "==> game/bin/{libRiverSimGD,libSwiftGodot}.dylib gebaut + signiert"
