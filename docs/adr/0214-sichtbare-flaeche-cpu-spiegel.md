# Raycast trifft die sichtbare Fläche: CPU-Spiegel der Shader-Höhe

Raycast, Pinselkuppel, Strich-Beginn und Kameraziel liegen auf dem, was man sieht: Sim-Höhe plus Render-Verschiebung (#153) plus Kronendach (#152). Der Pinsel selbst wirkt weiter auf die Sim-Zelle unter dem Treffer (x/z → Gitterposition). Seen tragen weder Verschiebung noch Dach (Schutzmaske), dort bleibt es die Sim-Höhe.

Weil die sichtbare Höhe im Vertex-Shader entsteht, rechnet GDScript dieselben Formeln nach:
- Dachzuschlag wie im Terrain-Vertex-Shader (`lift_f`): unter `canopy_lift_lo` hebt nichts, sonst das Minimum aus eigener Maske und dem Mittel der vier diagonalen Abgriffe im Abstand `canopy_lift_smooth_texels`, dazwischen bilinear. Vorher fehlte die Glättung (Review Neon Nr. 2), am Bestandsrand schwebten Kuppel und Raycast-Treffer um die volle Dachhöhe über dem Bild. Wächter `tests/canopy.gd` (Bestandsrand). Mit Einzelbäumen (#236) hebt das Dach nicht, Kuppel und Ziel liegen dann am Boden.
- Anteil der echten Verformung nach Geländealter wie `relief_lift` im Terrain-Shader: auf jungem Relief nur Schattierung, ab `age` voll (Smoothstep).
- Pinselgewicht (1 − d²)^p wie `Terrain.forEachBrushCell` (p = 2) und `Terrain.pickaxe` (p = 4).

Die Maske wird erst beim ersten Raycast nach einem Upload in Floats gewandelt.

Betrifft: `Main._raycast_surface`, `Main._surface_y`, `Main._forest_lift_at`, `Main._canopy_vertex_lift`, `Main.relief_geometry_fade`, `Main.brush_weight`, `shaders/terrain.gdshader`
