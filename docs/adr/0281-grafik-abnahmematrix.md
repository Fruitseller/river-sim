# Abnahmematrix der Landschaftsqualität: drei feste Welten und Kameras

Für reproduzierbare Vorher/Nachher-Vergleiche von Grafik- und Simulations-Tickets gibt es eine verbindliche Matrix aus Vergleichswelten und Kamerapositionen (Issue #150, Spec #156, Parent #117). Ihre Vertragsprüfungen laufen ungegatet in der Pflichtsuite, der Baseline-Lauf der physikalischen Felder ist gegatet (`RS_MEASURE=1`, Endung `Diagnostic`, ca. 15 min für 3 Seeds × 100k Jahre bei n = 720).

Weltauswahl:
- Seed 1337, „Flusstal Soča": Referenzwelt der Studie #116; steiles Kerbtal, canyonartiger Hauptfluss, bewaldete Talsohle, Grate, Mündung ins Meer.
- Seed 42, Binnenseen und Beckenlandschaft: dokumentiert in #121/nickmcd für füllende und schneidende Krater- und Beckenseen, breite Verlandungszonen, Uferlinien.
- Seed 20, hochalpines Massiv: laut `docs/melt-runoff-measurements.md` größte Spitzenhöhe (maxH 0.75), die meisten schneegespeisten Läufe (306), glaziale Kare.

Die drei Vorlagen-Kameras (#174, Paket E) gibt es zweimal: als Tasten-Presets F1–F3 in `Main.gd` (`CAMERA_PRESETS`) und als Matrix-Kameras. Pitch ist bei allen dreien gleich, die Distanz bei Tal und Nah, sonst zeigt der Abnahmebogen eine andere Ansicht als die Taste. Ziel und Yaw rechnen die Tasten adaptiv aus der laufenden Welt, die Matrix hält sie je Seed fest (Reproduzierbarkeit); ebenso die Distanz des Dioramas, die im Spiel aus der Land-Bounding-Box folgt (`fill`, `Main.gd` `frame_land`, nachgemessen in `game/tests/ui_layout.gd`). `scripts/graphics-matrix.sh` muss dieselben Werte kennen.

Betrifft: `GraphicsMatrixTests.matrixWorlds`, `testCameraPresetsMatchTheMatrix`, `scripts/graphics-matrix.sh`, `game/scripts/Main.gd` (`CAMERA_PRESETS`)
