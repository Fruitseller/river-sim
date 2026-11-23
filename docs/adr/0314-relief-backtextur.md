# Render-Verschiebung von Rinnen und Graten nur über die Backtextur

Die Verschiebung von Rinnen, Graten, Felsrippen und Felsbänken (Issue #153, Look-Iteration 7) ist eine GPU-Render-Ableitung: `relief_bake.gdshader` rechnet sie einmal je Terrain-Update in eine Textur, `terrain.gdshader` liest sie nur. Headless ist davon nichts ausführbar, deshalb wird wie bei der Wasser-Kalibrierung (#92) die Struktur des Uniform-Wegs gepinnt: welcher Shader welche `relief_*`-Uniform default-frei deklariert und liest, dass die Kodierung die Verschiebung abdeckt und dass der Terrain-Shader nur die Backtextur liest. Spiegel der Zahlen und Brücke prüft `CalibrationRegistryTests` (#213), End-to-End `game/tests/relief.gd`.

Der Terrain-Shader wertet den Filter nie selbst aus: pro Vertex kostete das in der Studie 35,6 ms je Bild. Die Vertex-Stufe liest die Höhe, die Pixel-Stufe Steigung und Rinnen mit genau einem Abgriff je Pixel (Review zu #174).

Die Kodierung muss die größte vorkommende Verschiebung abbilden. Rinnen und Felsrippen bleiben unter `2 · strength · scale · hscale` (Summe der Oktaven < 2 × erste Oktave), Grate unter ihrem tanh-Deckel `ridgeCap`. Der Kanal ist 0…1 mit Mitte 0.5, also ± 0.5 / `heightCode` Einheiten.

Betrifft: `ReliefRender.strength`, `ReliefRender.scale`, `ReliefRender.ridgeCap`, `ReliefRender.heightCode`, `game/shaders/relief_bake.gdshader`, `game/shaders/terrain.gdshader` (`relief_pixel`), `ReliefUniformsTests`
