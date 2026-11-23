# Einzelbäume über einen Compute-Pass statt fester Instanzen

Der Wald besteht aus Einzelbäumen (#236); das nimmt die Entscheidung aus #152 zurück, Instanzbäume abzuschaffen. Das Kronendach im Terrain-Shader bleibt als Waldboden (`tree_instances`). Ohne RenderingDevice (Compatibility-Renderer, headless) gibt es keine Einzelbäume, `available()` ist falsch und Main zeigt das Kronendach von #152.

GPU-getrieben wie die Vegetation in Horizon Zero Dawn: ein Compute-Pass (`tree_place.glsl`) geht jedes Bild ein festes, verwackeltes Gitter je Stufe um die Kamera ab, liest Höhe, Verschiebung und Waldmaske aus denselben Texturen wie das Terrain-Material und schreibt nur die Bäume, die stehen und zu sehen sind, in vier indirekte MultiMeshes (Nadel- und Laubbaum in voller Form nah, grobe Mischform fern und für die Schattenkarte). Die CPU schreibt keinen Transform, sie startet den Pass mit Kamera und Blenden; im Zeitraffer lädt sie weiter nur die Waldmaske hoch.

Verworfen: Kacheln mit festen Instanzen (der erste Wurf, `docs/graphics-quality.md` § Einzelbäume). Jede Instanz kostet dort ihren Vertex-Shader, auch wenn ihr Baum ausgedünnt oder ohne Wald ist. In `nah` waren das 42 Mio. Primitive im Hauptpass für rund 20.000 sichtbare Bäume, mit Schatten 134 Mio. Der Compute-Pass verwirft solche Bäume vor dem Zeichnen und cullt selbst gegen das Frustum; die MultiMeshes tragen deshalb eine AABB über die ganze Welt und werden von Godot nie gecullt.

Kartensymbol: Die Baumgröße wächst mit dem Abstand d, k(d) = K_NEAR · (d / D_NEAR)^K_EXP (1 … K_MAX). Damit der Wald gleich dicht wirkt, dünnt er mit 1/k^THIN_EXP aus: jeder Baum hat einen Rang und schrumpft weg, sobald Rang · k^THIN_EXP gegen 1 geht. Stufe L trägt die Ränge [2^−(L+1), 2^−L) (die letzte [0, 2^−L)) mit Gitterabstand `BASE_SPACING · 2^((L+1)/2)`; ab `level_range(L)` zeigt sie keinen Baum mehr. THIN_EXP = 1,7: 2 hielte die Deckung genau gleich, etwas weniger lässt die Kronen in der Ferne überlappen (geschlossener Wald).

Ein Mesh trägt beide Arten (`VERTEX`/`NORMAL` Nadelbaum, `CUSTOM0`/`CUSTOM1` Laubbaum, gleiche Topologie); `tree.gdshader` mischt je Instanz nach dem Nadelbaum-Anteil. Wandert die Baumgrenze, verwandelt sich der Baum, statt umzuspringen. Im Mesh-Bau laufen die Hilfsfunktionen über `Array` statt `PackedVector3Array`, weil Packed-Arrays als Kopie übergeben würden.

Thread- und Reihenfolge-Regeln:
- `_rd` und die Compute-Ressourcen werden nur auf dem Render-Thread benutzt. Die MultiMesh-RIDs werden einmal in `setup` erfasst, weil `_exit_tree` `lists` auf dem Haupt-Thread leert.
- Erst `multimesh_allocate_data`, dann das Mesh setzen: erst dann füllt Godot den Kommando-Puffer (`[Indexzahl, Instanzen, 0, 0, 0]`, gemessen mit 4.7.2).
- Bei angehaltenem Renderloop (Leerlauf) läuft kein Pass, sonst sammelten sich die Aufträge im nie abgeschickten Bild.
- Tauscht Main die Backtextur der Verschiebung, rendert die neue erst nach diesem Pass (SubViewport im selben Bild). In diesem Bild gilt deshalb noch `relief_prev_tex` (Blende 0).
- Der alte Uniform-Satz wird sofort freigegeben; er fiele sonst erst mit dem Shader, und das Ping-Pong der Verschiebung erzeugt mehrmals je Sekunde einen neuen.

Betrifft: `ForestTrees.gd` (`THIN_EXP`, `level_k_end`, `setup`, `_process`, `_dispatch`, `_mm_rids`, `_last_relief`), `TreeMesh.gd` (`build`, `_midpoint`), `shaders/tree_place.glsl`, `shaders/tree.gdshader`
