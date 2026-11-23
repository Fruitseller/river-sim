# Flächen-Vertrag der Terrain-Kacheln

`game/tests/terrain_tiles.gd` (#235) prüft den Flächen-Vertrag von `scripts/TerrainTiles.gd`, auf dem die Flussbänder stehen (sie nehmen ihre Höhen von genau dieser Fläche, SimRender `renderSurfaceHeight`). Braucht die GDExtension nicht.
- Die Kacheln bilden zusammen dieselbe Dreiecksmenge wie das frühere PlaneMesh (gleiche Punkte, Teilung entlang der Anti-Diagonale), auch mit schmaler oder einzelner letzter Kachel.
- Die Zahl der Quads ist (grid − 1)², ohne Lücke und Doppelung.
- Jede Kachel-AABB enthält alle ihre Vertices, sonst cullt Godot eine sichtbare Kachel; auch bei Dichte 2 und 4.
- Eine explizit gesetzte Kachelgröße gewinnt gegen `RS_TILE_QUADS`.

Verglichen wird in Gitterindizes, nicht in Weltkoordinaten: das PlaneMesh summiert seine Positionen schrittweise auf, die Kacheln rechnen sie exakt; in Weltkoordinaten unterschieden sie sich in der 4. Stelle.

Betrifft: `game/tests/terrain_tiles.gd`, `game/scripts/TerrainTiles.gd`
