# Geteilte Formeln zwischen Sim-Kern und Färbung haben genau eine Quelle

Mehrere Größen, die Sim und Render beide brauchen, stehen nur einmal in `Terrain` als `static`-Funktion; `SimRender.TerrainColorRenderer` ruft sie über den rohen Puffer auf, statt sie nachzuschreiben.

- `snowCoverage(swe:ref:)` = `S/(S + ref)` (dieselbe Sättigung wie die Stream-Map). Wächter `ClimateSnow.testSnowCoverIsTheSingleSourceForColouring`. Ohne Klima fällt `snowCover` auf das Höhenband (`HeightBands.snowAmount`) zurück, also exakt auf das Verhalten vor #33.
- `iceCoverage(thickness:ref:)` = `I/(I + ref)`. Wächter `Glacier.testIceCoverIsTheSingleSourceForColouring`. Ohne Eisfeld ist die Deckung 0 und der Renderer malt nur Schnee wie vor #35.
- `macroSlope` (±2 Zellen, Mittel beider Achsen) ist die einzige Quelle für „ist das ein Hang?" (Vegetation, Biomfärbung, Baumplatzierung). Seit der Pre-Erosion trägt jede Zelle feine Rinnen; die Per-Zell-Steigung wäre überall steil und wüsche Bewuchs und Farbe aus allen Tälern (Kalibrier-Kaskade, Issue #50). Gültig nur für 2 ≤ i,j ≤ n−3, der Aufrufer hält den Rand frei.
- `vegetationSuitability` (Eignung aus Höhe, Makrosteigung, Feuchte) speist das Relaxationsziel von `veg` und den Grünanteil der Färbung. Vorher gab es zwei Kopien mit auseinandergelaufenen Konstanten (Höhenabfall ab 0.5 bzw. 0.6, Regenfaktor 1.3 bzw. 1.2), die Färbung zeigte also nicht ganz, was die Sim rechnet (Issue #4).

Betrifft: `Terrain.snowCoverage`, `Terrain.snowCover`, `Terrain.iceCoverage`, `Terrain.macroSlope`, `Terrain.vegetationSuitability`, `SimRender.TerrainColorRenderer`
