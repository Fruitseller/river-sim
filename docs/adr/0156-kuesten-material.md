# Strand und Felsküste aus dem Zusammenhang je Küstenpunkt

`CoastMaterial` (Issue #174, Paket C) bestimmt, welche Landzellen an der Küste Sand tragen und welche Fels sind; zustandslos, Kalibrierung `WaterRender` § Strand und Felsküste, Wächter `SimCoreTests/CoastMaterialTests.swift`. Die Gewichte gehen im `TerrainColorRenderer` in Sand (A-Kanal der Makrofarbe) und Fels (G-Kanal der Materialgewichte).

Höhe und lokale Steigung allein reichen nicht: `Terrain.wavePass` hält JEDE Küste am selben Wellen-Talus, Bucht, Landzunge und Steilküste unterscheiden sich darin kaum (gemessen, `docs/river-coast-render-measurements.md` §E). Alle Küstenzellen waren Strand, ein gleichbreiter Ring um die Insel. `shore` liest deshalb je Küstenpunkt den größeren Zusammenhang:
1. Rückland-Relief binnen `beachReliefRadiusCells` (8): flache Küstenebene trägt Strand, ein Steilhang kommt mit Fels oder Bewuchs bis ans Wasser.
2. Offenheit: Meeresanteil im Fenster als Stellvertreter für Wellenenergie (die Sim hat kein Wellenfeld; `wavePass` ist lokal, ohne Richtung oder Fetch). Geschützte Bucht sammelt Sand, offene Landzunge wird abgetragen und wirkt steiler.
3. Sedimentzufuhr nahe einer Mündung (nach Einzugsgebiet): dort liegt Sand auch an steilerer Küste, das Tal öffnet das Rückland.
4. Rauschen entlang der Küste bricht den Verlauf auf. Es hängt nur an der Zellenlage und springt im Zeitraffer nicht, wenn die Küste wandert.

Jede Saumzelle erbt Strandbreite und Steilküsten-Anteil von ihrer Küstenzelle. Das Meer ist `h ≤ sea`, dieselbe Definition wie `openWaterSurface`.

Einzelentscheidungen mit Befund:
- Fels liest die Kliffhöhe direkt hinter der Küste (`cliffRiseRadiusCells`), nicht das Rückland-Relief (Radius 8): darüber wurde eine flache Uferterrasse vor einem Berg zur Felsküste, dunkles Geröll auf ebenem Boden (Befund #174, Seed 42 Südküste). Fels liegt nur auf der Kliffwand selbst (`cliffFaceSlopeLo/Hi`), nie auf der Terrasse davor.
- Sand als Vereinigung kreisförmiger Säume je Küstenpunkt statt Breitensuche mit 8 gleichen Schrittlängen: deren quadratische Ausbreitung plus wechselnde Breite erzeugte Rauten im Sand auf glattem Gelände.
- Die Wasserlinie (Küstenrampe des Wellen-Talus) ist steiler als das Steigungsfenster; ohne Ausnahme lag der Sand als Polster HINTER einem grünen Streifen am Wasser (Hill-Climber Nr. 8). Bis `beachWaterlineHeight` über dem Meer zählt die Steigung nicht.
- Über dem Gerinne einer Mündung liegt kein Sand (`clearRiverBeds`): der Saum reichte über das Gerinne jeder großen Mündung (Sand-Byte 255 auf den letzten zwei bis vier Landzellen, Seed 1337 Jahr 20.000), Sand lag quer über dem Fluss. Je gemalter Mündung (`renderMinCells`) wird der Saum entlang des D8-Hauptlaufs `mouthClearCells` Zellen stromauf in Band-Halbbreite gelöscht, mit einer Zelle weichem Rand.
- Delta-Inseln (Issue #174, Punkt 26; flache Komponenten bis `deltaIslandMaxHeight`, die an kein höheres Land grenzen, Mündungsbarren aus `Terrain.deltaDeposit`) tragen Sand, wo das Strandmodell sie als offene Landzunge kahl ließe. Angeschlossene Delta-Ebenen bekommen einen schmalen Sandrand, dahinter Bewuchs; über die Mündungszufuhr allein endete die Regel 16 Zellen neben der Mündung, und die Ebene dahinter lag voll im Strand.

Die Stellschrauben stehen in einer eigenen `Calibration`-Struktur nur, damit die Messreihe (`CoastShapeTests`) Alternativen durchrechnen kann; die Produktion liest immer `.calibrated`.

Betrifft: `CoastMaterial`, `CoastMaterial.shore`, `CoastMaterial.beach`, `CoastMaterial.beachReach`, `CoastMaterial.clearRiverBeds`, `CoastMaterial.deltaIslands`, `CoastMaterial.alongShoreNoise`, `CoastMaterial.sand`, `CoastMaterial.cliff`, `CoastMaterial.Calibration`
