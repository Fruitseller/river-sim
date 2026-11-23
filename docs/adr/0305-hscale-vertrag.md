# Überhöhung hscale: ein Wert, jede Anwendung gepinnt

`RenderContract` (Issue #51) hält die Zahlen, die Godot-Schicht, GDExtension und Shader gemeinsam annehmen müssen. Auslöser war Drift genau in der Lücke, die headless nicht ausführbar ist: der Shader-Default von `hscale` stand auf 26.0, während `Main.gd` mit 24.0 rechnete. Seit #213 holt `Main.gd` die Zahl über die Brücke; der Wächter prüft, dass derselbe Wert als Uniform ankommt.

Gepinnt wird nicht nur die Deklaration, sondern jede Anwendung im Terrain-Shader: ein zusätzlicher Faktor am Displacement (`* hscale * 1.08`) oder eine eigene Konstante in den Normalen ließe den Vertrag grün und das Bild trotzdem abweichen. Die Anwendungen sind Vertex-Höhe, Vertex- und Pixel-Normale, die Welt-Y-Koordinate der triplanaren Materialschichten und die Weltsteigung der Gletscherspalten und des Raster-Wassers an Wänden; eine Zählung im Wächter fängt jede neue, ungeprüfte Anwendung. Die Vertex-Normale trägt dasselbe Vorzeichen wie die Pixel-Normale (hU bei +z), weil Godots Schatten-Normal-Bias sie liest (Review zu #174, vorher `-(hD - hU)`).

Die Render-Verschiebung (#153) addiert sich zur Vertex-Höhe unskaliert: sie liegt schon in Welteinheiten vor, weil der Back-Pass die Überhöhung genau einmal anwendet. Er bekommt denselben Uniform aus `Main.gd` und rechnet damit Gratdeckel, Felsrippen-Steigung und Felsbank-Höhe um.

Über Wasser gilt der Land-Lift `riverLift` (0.35) nicht: `ribbonLakeSurfaceLift` und `ribbonSeaSurfaceSink` müssen deutlich kleiner bleiben, sonst schwebte das Band als Platte über der Fläche.

Betrifft: `RenderContract.heightScale`, `RenderContract.riverLift`, `WaterRender.ribbonLakeSurfaceLift`, `WaterRender.ribbonSeaSurfaceSink`, `game/shaders/terrain.gdshader`, `game/shaders/relief_bake.gdshader`, `Main.gd` (`hscale`), `RenderContractTests`
