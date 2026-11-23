# Zeitraffer-Überblende der Flussbänder

Die Band-Geometrie kommt höchstens einmal je `RenderState.ribbonRebuildSeconds` und wurde bis Issue #174 hart ersetzt, während Farbe, Material, Wald und Höhe schon über ihre Blende glitten (#170, #172). Seit dem Mäandergürtel (#174 B) wandern die Läufe so schnell, dass jeder Band-Bau sichtbar springt.

Die Blende dauert genau so lange wie der Band-Deckel (`RIBBON_FADE_SECONDS` in `Main.gd`): im Zeitraffer liegen zwei Bauten nie dichter, auch bei unregelmäßigem Takt, die Blende endet also vor dem nächsten Bau, und kein halb aufgelöster Stand wird verworfen. Länger hieße genau das, kürzer hieße Stillstand zwischen den Bauten.

`Main.gd` führt zwei Band-Meshes. Das alte wandert nur im Zeitraffer-Takt ins ausblendende Mesh (Pinsel, Sprung, Laden zeigen den neuen Stand sofort), und es ist im selben Aufruf sichtbar, in dem die Blende auf 0 springt, sonst fehlte für ein Bild jedes Band.

Alter und neuer Stand teilen sich die optische Dicke (Befund #174, Seed 1337 / Jahr 2.305): wo beide liegen, decken sie zusammen genau wie ein Band. Lineares Mischen machte stehende Läufe mitten in der Blende durchsichtiger (0,95 → 0,72) und pulste im Band-Takt; wo nur einer liegt, blendet er stetig, ohne Pixel-Los (das zeichnete körnige Ufer). `water.gdshader` rechnet dieselbe Formel; `ribbon_blend` steht nur in `ribbon_fade_alpha`, als linearer Faktor pulsierte der Lauf.

Die Sedimentfahne kommt mit den Overlays und blendet mit ihnen; die Mip-Weichzeichnung allein glättete den Sprung nicht.

Betrifft: `RenderState.ribbonRebuildSeconds`, `game/scripts/Main.gd` (`RIBBON_FADE_SECONDS`, ausblendendes Band-Mesh), `game/shaders/water.gdshader` (`ribbon_fade_alpha`), `game/shaders/ocean.gdshader`, `RiverFadeTests`
