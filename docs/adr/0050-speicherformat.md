# Becken-Rolle als Byte im Spielstand, Wiederherstellung ohne Generierung

`Terrain.endorheicBasin` (Typ `BasinRole`, Issue #11) liegt als ein Byte je Zelle im Schnappschuss (`WorldSnapshot.uint8Fields`). Die Zuordnung `none = 0`, `dryBed = 1`, `water = 2` ist damit Teil des Dateiformats; sie zu ändern braucht eine neue Snapshot-Version.

Unbekannte Bytewerte (fremde oder defekte Datei; die Prüfsumme deckt nur Transportfehler ab) werden beim Laden zu `.none`. Das ist der neutrale Zustand, den `capEndorheicBasins` im nächsten Schritt ohnehin neu bestimmt. Ein Absturz oder eine halb typisierte Welt wäre die schlechtere Antwort.

Zum Wiederherstellen aus einem `WorldSnapshot` (Issue #8) legt `init(allocating:seed:)` nur die Puffer an und generiert nicht: jedes Feld kommt aus der Datei, ein `generate` davor (Breach und Spin-up) wäre reine Rechenzeit und würde überschrieben.

Betrifft: `BasinRole`, `BasinRole.init(persisted:)`, `Terrain.endorheicBasin`, `Terrain.init(allocating:seed:)`, `WorldSnapshot.uint8Fields`
