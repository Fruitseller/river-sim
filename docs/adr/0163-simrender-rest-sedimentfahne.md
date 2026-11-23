# Sedimentfahne als küstennaher Pfad auf der CPU

Die Trübung der großen Flüsse im Meer (Issue #174, Paket C) entsteht in `SedimentPlume` und nicht im Shader. Vorher legte der Shader eine Quellzelle je Mündung über eine Mip-Kette aus und zog sie entlang einer festen Strömung auf: die Fahne wurde mit jeder Stufe breiter und las sich aus der Ferne als brauner Rauchfächer, der unabhängig von der Küste ins offene Meer reichte. Jetzt läuft sie als kürzester Pfad über Meereszellen küstennah ab der Mündung, ein schmales Band (`plumeBandCells`), das mit der Pfadlänge abklingt. `ocean.gdshader` liest die fertige Dichte mit einer Abfrage.

Die Küstenströmung bevorzugt eine Richtung (`plumeUpstreamPenalty`, dieselbe Drift wie die Ozean-Wellen): stromauf klingt die Fahne schneller ab als stromab, quer zur Strömung reicht sie symmetrisch. Nur Mündungen ab `plumeMinDischargeCells` zählen; Überlappen zwei Fahnen, gilt die dichtere. Zustandslos, Cache in `RenderState`. Kalibrierung und Fracht-Stellvertreter: `WaterRender` § Sedimentfahne; Wächter: `SimCoreTests/SedimentPlumeTests.swift`.

Betrifft: `SedimentPlume`, `SedimentPlume.field`, `SedimentPlume.spread`, `SedimentPlume.mouths`, `game/shaders/ocean.gdshader`
