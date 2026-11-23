# Großform der Generierung: Gebirgskamm, sanftes Relief, Pre-Erosion

Großform (Issue #174, `RangeSkeleton` in `Landform.swift`): EIN Gebirgskamm entlang der langen Inselachse mit Seitenästen, Hügelland daneben, flache Ebene dahinter, zwei bis vier Täler vom Kamm zur Küste. Die Tektonik (`upliftBase`) liegt nur noch im Gebirgsgürtel. Dazu ein Randabstand (kein Land am Gitterrand) und eine Insel-Ellipse, die über ihre LANGE Halbachse normiert ist.

Gemessen (Produktion, Seeds 1337/42/20, `docs/zielbild-measurements.md`): Landanteil der vier größten Tieflandflächen in Jahr 2000 13/32/26 % → 48/62/52 %, erst jetzt erreicht eine davon die Küste (Reichweite 0,00 → 1,00). Land im Randring 659/0/280 → 0 Zellen. Eis in Jahr 100.000 auf Seed 42 0 → 529 Zellen. `LongRunCollapse` bleibt grün.

`rangeLandform = false` ist die Form davor (Grate über die ganze Landfläche), bit-identisch. Nur für Mechanik-Wächter, deren Testwelt Becken, Playas und Schlingen der alten Seed-1337-Welt braucht (`calibrationRangeLandform` in `SimCoreTests/TestCalibration.swift`).

Basisrelief 0,78, von 1,05 gesenkt (Nutzer: „zu extrem“): sanfteres Terrain gibt weniger Nadel-Gipfel und flachere, breitere Talböden; niedrigere Steigungen bringen mehr Reaches unter die Mäander-Schwelle und damit Platz für Fluss-Dynamik. 0,72 ebnete über 100k Jahre knapp unter den LongRunCollapse-Wächter (0,30) ein; 0,78 hält Marge.

Pre-Erosion: der runevision-Erosionsfilter (`ErosionFilter.swift`, stacked faded gullies) carvt verzweigte Rinnen und Grate einmalig ins frische Basisrelief. Das Terrain startet damit mit erodiertem Look, statt ihn über 10k+ Sim-Jahre einzucarven; die Sim läuft danach normal weiter, die Tropfen folgen den vorgecarvten Rinnen.

Betrifft: `SimConfig.rangeLandform`, `SimConfig.baseRelief`, `SimConfig.preErodeEnabled`, `SimConfig.preErodeParams`, `RangeSkeleton`, `ErosionFilter`
