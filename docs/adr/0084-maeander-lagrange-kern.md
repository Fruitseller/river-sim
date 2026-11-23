# Mäander als Lagrange-Zentrumslinien mit gedeckelter Migration

Ein Fluss ist für die Mäander-Migration eine persistente Polylinie mit Gedächtnis, nicht das Euler-Grid der D8-Entwässerung: sie wandert (Prallhang erodiert, Außenkurve verschiebt sich), schnürt Schlingen ab (Cutoff) und hinterlässt Altarme. Der Kern ist bewusst grid-frei und deterministisch und arbeitet nur auf Knotenkoordinaten (kontinuierliche Gitterkoordinaten, x = Spalte i, z = Zeile j). Die Rückkopplung ins Höhenfeld (Bett-Carve, Ufer-Verschiebung) macht separat `Terrain.meanderStamp`.

Festlegungen des Migrationsschritts (`MeanderState.migrate`):

- Das Flachland-Gate (`mobility`) misst die LÄNGSneigung entlang des Laufs, nicht die Querneigung, die an eingetieften Kanälen immer steil ist. Ufer-Kohäsion: bewachsene Ufer (`Terrain.riparianVegAt`) migrieren langsamer, Faktor (1 − `meanderCohesion`·riparian). Defaults 0 halten die entkoppelten Kernel-Tests unverändert.
- Sinuositäts-Deckel: über `meanderMaxSinuosity` migriert ein Lauf nicht weiter (sonst tangeln einzelne Läufe zu Knäueln, Sinuosität 7..26). Glättung und Cutoff laufen weiter und holen ihn unter die Schwelle zurück.
- Upstream-gewichtete Krümmung (Ikeda–Parker–Sawai): die Ufererosion hängt von der stromauf integrierten Krümmung ab (das ufernahe Geschwindigkeitsfeld laggt), die Erosionsspitze verschiebt sich stromab, Schlingen werden asymmetrisch statt symmetrisch. EMA über steigendes i (= stromab). Danach wird auf die gleiche Gesamtstärke normiert: die EMA ist ein Tiefpass und würde sonst Amplitude und Mäander-Rate dämpfen; der Skew verschiebt nur die Phase.

Betrifft: `MeanderNode`, `RiverChannel`, `MeanderState.migrate`, `MeanderState.lateralStep`, `SimConfig.meanderMaxSinuosity`, `SimConfig.meanderSkew`, `SimConfig.meanderCohesion`, `Terrain.meanderStamp`
