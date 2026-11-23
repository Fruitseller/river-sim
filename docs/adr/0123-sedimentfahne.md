# Sedimentfahne im Meer als küstennaher Pfad

Nur die großen Flüsse bekommen eine Trübungsfahne (Issue #174, Paket C). `SimRender.SedimentPlume` rechnet sie als Dichte je Meereszelle: ein Pfad ab der Mündung über Zellen küstennah (`plumeBandCells`), der mit der Pfadlänge abklingt (`plumeDecayCells`); `ocean.gdshader` liest die Dichte mit leichter Weichzeichnung und färbt das Wasser. Die Fahne bevorzugt die Richtung der Küstenströmung (Drift der Ozean-Wellen, `oceanWaveDriftX/Z`), damit Fahne und Wellen in dieselbe Richtung ziehen; die Pfadkosten steigen gegen die Strömung (stromab 1×, quer 1 + p/2, stromauf 1 + p; mit p = 2 klingt sie stromauf auf einem Drittel der Länge ab).

Fracht: im Sim-Kern gibt es kein Frachtfeld. Stellvertreter ist das Relief des Einzugsgebiets (höchster Punkt über dem Meer): nach Milliman & Syvitski (1992) steigt die Schwebstofffracht mit Fläche UND maximaler Höhe des Einzugsgebiets; Gebirgsflüsse trüben das Meer, Tieflandbäche kaum. Messreihe: `docs/river-coast-render-measurements.md` §C und §F.

Verworfen (Befund „Rauchfächer“, §F): der Shader legte EINE Quellzelle über eine Mip-Kette aus und zog sie entlang der Strömung auf; Breite und Reichweite wuchsen mit jeder Stufe (bis 32 Zellen breit), unabhängig von der Küste, dazu ein lehmbrauner Ton bei 60 % Deckung.

Betrifft: `WaterRender.plumeMinDischargeCells`, `WaterRender.plumeFullRelief`, `WaterRender.plumeDecayCells`, `WaterRender.plumeBandCells`, `WaterRender.plumeUpstreamPenalty`, `WaterRender.oceanPlumeLod`, `SimRender.SedimentPlume`, `game/shaders/ocean.gdshader`
