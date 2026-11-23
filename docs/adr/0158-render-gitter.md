# Band-Geometrie folgt der gerenderten Oberfläche

Die Land-Bänder sampeln ihre Höhen von der SICHTBAREN Oberfläche (`renderSurfaceHeight`), nicht von den Sim-Höhen. Auf Steilstrecken weicht das gröbere Render-Mesh um ein Vielfaches von `RenderContract.riverLift` von den Sim-Höhen ab; ein Band auf Sim-Höhen tauchte dort abwechselnd unter das Mesh und ragte an Dreieckskämmen als blaue Zacken heraus (Nutzer-Screenshots, Steil-Läufe im „balanced"-Gitter 384 auf dem damaligen 832er-Feld).

`Main.gd` meldet die Auflösung seines Terrain-Gitters (`terrain_grid`) über `SimNode.setRenderGrid`. Ohne Aufruf (0 = unbekannt) gilt volle Auflösung; die headless Wächter bleiben damit unverändert. Bei `renderGrid >= n` ist das Ergebnis identisch zu `bilinearGrid`.

Innerhalb eines Quads ist die sichtbare Fläche die Triangulierung des Meshes, nicht die Bilinear-Fläche; auf steilen Quads weichen beide um den halben Quad-Twist ab, und das Band tauchte gegen die Bilinear-Annahme weiter ein und aus. Jedes Quad ist entlang der Anti-Diagonale geteilt (von (1,0) nach (0,1)): unter ihr das Dreieck (0,0)(1,0)(0,1), über ihr (1,1)(0,1)(1,0). Das war die Teilung von Godots PlaneMesh; `game/scripts/TerrainTiles.gd` hält seit #235 denselben Vertrag.

Die Index-Klemme arbeitet auf Int-Gittergrenzen (0…renderGrid − 2) und bleibt bewusst eine Int-Klemme; nur die fraktionalen Gewichte laufen über `clamp01`.

Betrifft: `renderSurfaceHeight`, `bilinearGrid`, `RenderState.renderGrid`, `WorldSession.renderGrid`, `SimNode.setRenderGrid`, `game/scripts/TerrainTiles.gd`
