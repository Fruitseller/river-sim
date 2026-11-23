# Reihenfolge der Fenster über der Wassersäule

Die Form der Uferlinie rechnet der Terrain-Shader je Pixel aus der Wassersäule `pond = waterLevel − h` (volles Sim-Gitter, bilinear); der G-Kanal ist nur noch das Sichtbarkeits-Gate (Issue #32). Drei Fenster lesen `pond`: Farb-Kontur, Geometrie-Hub und Tiefen-Rampe. Ihre REIHENFOLGE ist die Kalibrierung: erst Farbe (ab `pondContourLo` 0.003), dann Geometrie (ab `geometryLiftLo` 0.015), die Tiefe (`lakeDepthLo` 0.004) füllt dazwischen. Verschiebt man eines allein, löst sich die Farbe von der gehobenen Wasserfläche.

Der Kontur-Fuß liegt bewusst unter der Hebe-Schwelle der Wasser-Geometrie, damit die Farbe bis fast an die echte Uferlinie reicht, während die Geometrie erst später sanft hebt.

Der Fuß ist zugleich die Präsenz-Schwelle des Altarm-Overlays (`SimRender.WaterFieldRenderer`): dessen Deckkraft wird im Shader mit dieser Kontur multipliziert, also darf das Overlay nur so tief stempeln, wie die Kontur noch zeichnet; sonst sind gerade die seichten Altarm-Enden unsichtbar. Wer den Fuß verschiebt, verschiebt beides.

Betrifft: `WaterRender.pondContourLo`, `WaterRender.pondContourHi`, `WaterRender.geometryLiftLo`, `WaterRender.lakeDepthLo`, `WaterRender.lakeDepthSpan`, `SimRender.WaterFieldRenderer`, `game/shaders/terrain.gdshader` (`lift`, `lake_depth`)
