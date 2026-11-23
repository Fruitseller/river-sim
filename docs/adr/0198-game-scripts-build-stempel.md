# Build-Stempel: Godot-Seite bytegleich zum Shell-Skript

Godot lädt `game/bin/libRiverSimGD.so` blind; eine veraltete Library fiel sonst erst als "Nonexistent function ..." auf (real passiert mit `brush`). Deshalb rechnet die Godot-Seite den Stempel des Arbeitsverzeichnisses selbst und vergleicht ihn mit dem, der zur Bauzeit in `SimNode` eingebrannt wurde.

Das Verfahren muss bytegleich zu `scripts/build-stamp.sh` sein (Wächter: `game/tests/build_stamp_parity.gd`):

1. Alle regulären Dateien unter `Extension/Sources` und `SimCore/Sources`, außer dem generierten Stempel selbst (`Extension/Sources/RiverSimGD/Generated`, er hinge sonst von sich ab).
2. Pfade relativ zur Repo-Wurzel, sortiert (ASCII-Pfade, gleiche Ordnung wie `LC_ALL=C sort`).
3. Manifest-Zeile je Datei: `"<sha256>  <relpfad>\n"` (zwei Leerzeichen).
4. Stempel = sha256 des Manifests.

Zwei Folgen für den Code: `DirAccess.include_hidden` muss an sein, weil `find` auch Punktdateien sieht, sonst driften Shell- und Godot-Stempel auseinander. Ein fehlendes Verzeichnis wird bewusst nicht abgefangen: der Stempel weicht dann ab, und genau diese laute Reaktion ist gewollt.

Betrifft: `BuildStamp.gd` (`source_stamp`, `check`, `_collect`), `scripts/build-stamp.sh`
