# Build-Stempel gegen veraltete GDExtension-Libraries

Godot lädt die Library aus `game/bin/` blind und merkt nicht, wenn sie älter ist als der Quellstand. Der Smoke-Test scheiterte real mit „Nonexistent function brush", weil die `.so` vor dem brush-Commit gebaut war. `scripts/build.sh` brennt deshalb einen Stempel des Quellstands in die Library ein (`Extension/Sources/RiverSimGD/Generated/BuildStamp.swift`), `scripts/start.sh` und `game/tests/smoke.gd` vergleichen ihn mit dem Arbeitsverzeichnis und brechen mit dem Rebuild-Befehl ab. `smoke.gd` prüft den Stempel als Erstes, sonst testet alles danach eine alte `.so` mit irreführenden Fehlschlägen.

Verfahren (Shell `scripts/build-stamp.sh` und GDScript `game/scripts/BuildStamp.gd` müssen bytegleich übereinstimmen):
1. Alle regulären Dateien unter `Extension/Sources` und `SimCore/Sources` sammeln, außer dem generierten Stempel selbst (sonst hinge der Hash von sich ab).
2. Pfade relativ zur Repo-Wurzel, in Byte-Reihenfolge sortiert (`LC_ALL=C`).
3. Manifest-Zeile je Datei: `"<sha256>  <relpfad>\n"` (zwei Leerzeichen wie sha256sum).
4. Stempel = sha256 des Manifests.

Nur Inhalt und Pfad zählen, nicht die mtime: ein `touch` löst keinen falschen Alarm aus, ein `git checkout` eines anderen Stands schon.

Marker und Hash stehen in der generierten Swift-Datei in einem String-Literal (`RIVERSIM_BUILD_STAMP:<hash>`) und landen lesbar in der `.so`/`.dylib`; der eingebrannte Stempel ist so ohne Godot-Start mit `grep -a` greifbar. Kein Treffer ist ein regulärer Fall (Library ohne Stempel) und muss mit Exit 0 als leere Ausgabe durchgehen (`|| true`); sonst bräche `set -e -o pipefail` schon an der Zuweisung ab, und genau dann fehlten Meldung und Rebuild-Hinweis. Leere Ausgabe gilt als veraltet. `build.sh` schreibt die Stempel-Datei nur bei Abweichung, sonst kompiliert SwiftPM das Modul jedes Mal neu, und prüft am Ende mit `build-stamp.sh --check`, dass der Stempel in der kopierten Library ankommt; sonst wäre die Prüfung von `start.sh`/`smoke.gd` wirkungslos.

Parität (#52, vorher Review-Zusage): `game/tests/build_stamp_parity.gd` führt die Shell-Seite selbst aus, statt ihren Wert durchzureichen; nur so vergleicht der Test zwei Verfahren statt zwei Aufrufe desselben. Driften beide Seiten auseinander, meldet jeder Start fälschlich eine veraltete Library, oder eine wirklich veraltete fällt nicht mehr auf. Der Test braucht die GDExtension nicht und sagt deshalb auch bei gescheitertem Extension-Build etwas aus. In CI läuft er nach dem Bau, damit die generierte `BuildStamp.swift` existiert und mitgeprüft wird, dass beide Seiten dieselbe Datei ausnehmen.

Aufrufe: `build-stamp.sh` bzw. `--source` (Stempel des Arbeitsverzeichnisses), `--library` (eingebrannter Stempel), `--check` (Vergleich, Exit 1 mit Meldung).

Betrifft: `scripts/build-stamp.sh`, `game/scripts/BuildStamp.gd`, `scripts/build.sh` (Stempel-Abschnitt), `scripts/start.sh`, `game/tests/smoke.gd`, `game/tests/build_stamp_parity.gd`, `.github/workflows/ci.yml` (Paritäts-Schritt)
