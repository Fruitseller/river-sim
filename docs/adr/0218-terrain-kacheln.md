# Terrain in Kacheln mit eigener AABB und PlaneMesh-gleicher Fläche

Das Terrain besteht aus Kacheln (#235) statt einem PlaneMesh über die ganze Insel. Jede Kachel ist eine eigene MeshInstance3D mit eigener AABB, damit Godot im Hauptpass und in jeder Schattenkaskade nur zeichnet, was im Frustum liegt; vorher schaltete `extra_cull_margin = 1000` das Culling ab. Gemessen sind die Kacheln leistungsneutral (±0,7 ms, `docs/perf-measurements.md` § V), die Bildzeit folgt den Pixeln. Sie sind die Struktur für Objekte je Kachel.

Vertrag, damit Shader, Bänder und Raycast nichts von den Kacheln wissen müssen:
- Vertices in Weltkoordinaten (Instanz im Ursprung); der Terrain-Vertex-Shader leitet seine UV wie beim PlaneMesh aus `VERTEX.xz` ab (`world_uv`).
- Bei Dichte 1 liegen die Vertices genau auf den Punkten des Render-Gitters (Abstand world_size / (grid − 1)), jedes Quad ist entlang der Anti-Diagonale geteilt wie Godots PlaneMesh (prevrow+i ↔ thisrow+i−1). Die sichtbare Fläche ist dieselbe wie vorher, und die Bänder, die ihre Höhen von genau dieser Fläche nehmen (`sim.setRenderGrid`, `RenderSupport.renderSurfaceHeight`), liegen weiter richtig.
- Benachbarte Kacheln teilen ihre Randpunkte exakt: keine Risse.
- Dichte > 1 (`set_density`) bricht den Bänder-Vertrag; T-Fugen an der Grenze vermeidet nur eine Verschiebung von null am Rand. Produktiv nutzt das nichts, die Gelände-Verfeinerung (#238) arbeitet über Texturen.

Kachelgröße 64 Gitterabstände: bei 720 Punkten 12 × 12 Kacheln, die letzte Reihe schmaler (719 = 11 · 64 + 15). Kleiner heißt feineres Culling, aber mehr Zeichenaufrufe (je Kachel einer im Tiefen-Vorpass, einer im Hauptpass, einer je Kaskade); in der Totalen kosten die 144 Kacheln gemessen rund 0,4 ms. `RS_TILE_QUADS` für A/B.

Die AABB-Höhe ist konservativ über die ganze Welt statt je Kachel: gecullt wird vor allem nach x/z, und eine zu flache AABB ließe eine sichtbare Kachel verschwinden.

Die Dreiecke stehen in der Reihenfolge des alten PlaneMesh (von +z nach −z, je Zeile von +x nach −x). Die Reihenfolge kostet messbar: in der Gegenrichtung lag dieselbe Kachel in `diorama` bei 3456×2104 um 0,9 ms über dem PlaneMesh, so herum gleich (`docs/perf-measurements.md` § V).

Betrifft: `TerrainTiles.gd` (`TILE_QUADS`, `build`, `_grid_mesh`, `_axis`, `set_density`), `RenderSupport.renderSurfaceHeight`, `game/tests/terrain_tiles.gd`
