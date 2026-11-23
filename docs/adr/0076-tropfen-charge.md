# Tropfen-Charge: Zahl mit Übertrag, Zufall am Tropfen-Strom

Die Tropfenzahl eines Schritts ist ∝ Zeit × Fläche, die Dichte auf n = 640 kalibriert (`density = n²/640²`). Der angebrochene Rest wandert über `dropCarry` in den nächsten Schritt, statt je Schritt auf 1 aufgerundet zu werden (Issue #2, Ursache 3): bei dt = 0.2 J./Frame verlangte die Rate 0.09 Tropfen, `max(1, …)` lieferte 1, also über 11× zu viel Droplet-Erosion gegenüber demselben Zeitraum als Sprung. `dropletCount` ist nicht `private`, damit der Wächter die reine Zählung prüfen kann.

Der Zufall einer Charge hängt an der laufenden Nummer des ersten Tropfens (`dropsEmitted`), nicht an der Zahl der Schritte; beide Zähler gehören damit zum Determinismus und reisen im Spielstand (s. Zustands-Inventar).

Die Tropfen starten nach `flowWeight`, derselben Gewichtungsregel wie D8 und MFD (Issue #36): wo Schmelzwasser abfließt, starten auch mehr Tropfen.

Stream-Map: die Besuchs-RATE (Besuche/Jahr) wird geglättet (nickmcd lrate, dt-skaliert über `relaxFraction` mit `streamMapMemoryYears`) und dann gesättigt: nur konsistent befahrene Zellen hellen auf, einzelne Zufallspfade verblassen. EWMA und Sättigung laufen fusioniert und datenparallel, bit-identisch zu "erst EWMA-Schleife, dann `deriveStreamMap`".

Betrifft: `Terrain.dropletCount`, `Terrain.dropCarry`, `Terrain.dropsEmitted`, `Hydraulic.erode`, `Terrain.flowWeight`, `Terrain.streamMap`, `SimConfig.streamMapMemoryYears`
