# Werkzeug-Vertrag zwischen Game-Layer und BrushTool

Über die Brücke geht nur eine Zahl (`SimNode.brush(mode:)`, Issues #53, #79). Ihre Bedeutung steht zwangsläufig doppelt: als `case` von `BrushTool` (seit #79 in SimCore) und als `"mode"` in der Werkzeug-Tabelle von `Main.gd`. Die Zahl ist der Rohwert der Aufzählung, lückenlos ab 0 in Tabellen-Reihenfolge; sonst müsste der Game-Layer die Zuordnung kennen, die die Tabelle abschaffen soll. Die GDScript-Seite bleibt Text-Match, die Swift-Seite wird ausgeführt.

Verhindert werden soll eine Tabellenzeile ohne `case` (früher fiel der `switch` auf `default: break`, das Werkzeug malte nichts, und im Spiel sah das wie ein Physik-Bug aus) und ein `case`, das auf die falsche Terrain-Operation zeigt oder Argumente vertauscht. Ein Quelltext-Parser des `switch` sah vertauschte Argumente nicht und brach bei jeder Umformung ohne Verhaltensänderung. Deshalb läuft jedes Werkzeug auf seed-gleichen echten Terrains und seine charakteristische Wirkung wird geprüft.

Der Vergleich „sechs Werkzeuge, sechs verschiedene Wirkungen" ist bewusst redundant zu den Einzeltests: zwei `case`s auf derselben Operation erfüllen unter Umständen beide Einzel-Zusicherungen und fallen erst dort auf.

Für den Aufrau-Pinsel gibt es bewusst keine „Zerklüftung steigt"-Zusicherung: gemessen (n = 96, Seed 1337, Radius 12 Welteinheiten ≈ 8,8 Zellen) verschiebt ein Strich die mittlere 3×3-Abweichung nur in der vierten Stelle und je nach Pinselgröße in beide Richtungen; das Rauschen hat auf Zellskala zu wenig Amplitude gegen das erodierte Relief. Zugesichert werden vorzeichenbehaftetes Muster, Amplitude höchstens `0.005 · strength`, nichts außerhalb des Kreises, und dass wiederholte Striche dasselbe Muster vertiefen.

Betrifft: `BrushTool`, `SimNode.brush`, `game/scripts/Main.gd` (Werkzeug-Tabelle), `ToolContractTests`, `TerrainAPITests.testRoughenImprintsSignedNoiseInsideTheBrushOnly`
