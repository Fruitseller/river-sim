# Material des Mäandergürtels aus Bankalter und Zentrumslinie

`BarMaterial` (Issue #174, Paket C Teil 2) leitet Sand- und Kiesbänke, Scroll-Bars und die Verlandung der Altarme je Zelle aus dem Sim-Zustand ab; zustandslos, ändert das Terrain nie, Cache in `RenderState`. Leser sind `TerrainColorRenderer` (Sand im A-Kanal der Makrofarbe) und `WaterProtectMask` (kein Wald, keine Verschiebung auf frischen Bänken). Kalibrierung: `SimCore.WaterRender` § Mäandergürtel im Render; Wächter: `SimCoreTests/BarMaterialTests.swift`.

1. Sand nur auf der JUNGEN Gleithang-Bank direkt am Gerinne: jung nach `Terrain.barAge` (`barSandYearsLo/Hi`) UND nah an der aktuellen Zentrumslinie (`barSandReachLo/Hi`, in örtlichen Kanalbreiten aus `MeanderState.beltWidthCells`, dieselbe Kurve wie Bett und Band). Was der Lauf früher überstrichen hat, ist Aue, kein Sand.
2. Pionier-Grün dahinter: die Sim setzt den Bewuchs beim Stempeln auf 0 und lässt ihn über Jahrhunderte nachwachsen; die junge Bank liest über `barPioneer` grüner statt als kahler Trockenrasen.
3. Scroll-Bars als leise Rippen im Bewuchs über den Isolinien des Bankalters (jede Isolinie ist eine frühere Lage des Gleithangs). Die Höhe kann sie auf diesem Gitter nicht tragen; Senken grüner, Rücken magerer, nie heller Sand. Enger als `barScrollMinSpacingLo` Zellen blenden sie aus (Aliasing).
4. Altarme färben über ihr Alter (`MeanderState.oxbowAge`): Ried in der feuchten Senke, später ein Vegetationsbogen. Je Zelle zählt der JÜNGSTE Altarm; eine jüngere Bank (`barAge` kleiner als das Altarm-Alter) hat den Bogen überschüttet und gewinnt. Die Schleifenauswahl teilt sich der Gürtel mit Wasserfeld und Altarm-Bändern (`oxbowNodeRange`).

Einzelne Sandzellen ohne Bank daneben (feste Läufe stempeln je Schritt einzelne Zellen frisch) sind Sprenkel quer über die Aue; Sand bleibt nur, wo genug der 8 Nachbarn selbst Sand tragen (`barSandNeighbours*`). Pionier-Grün und Rippen werden erst NACH diesem Entsprenkeln um den Sand reduziert; mit dem rohen Sand verlor eine entfernte Sandzelle ihren Sand UND ihr Grün (kahler Punkt).

Der Abstand zur Zentrumslinie läuft parallel über Zeilenbereiche: jede Strecke liegt in den Zeilenbändern, die ihr Kasten berührt, jeder Bereich schreibt nur seine Zeilen, und geschrieben wird per Minimum, also reihenfolgeunabhängig. Beim Altarm-Stempel klemmt der Zeilen- und Spaltenbereich so, dass ein Knoten weiter als `reach` jenseits des Gitters nichts stempelt (Untergrenze über Obergrenze wäre ein Abbruch, wie bei `WaterFieldRenderer.stampCorridor`).

Betrifft: `BarMaterial`, `BarMaterial.field`, `BarMaterial.despeckle`, `BarMaterial.lineDistance`, `BarMaterial.stampOxbows`
