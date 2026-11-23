# Vertex-Vertrag der Band- und Korridor-Meshes mit den Wasser-Shadern

Die Bedeutung der Vertex-Attribute ist ein Vertrag mit `water.gdshader` und `corridor.gdshaderinc`; wer eine Kodierung ändert, zieht den Shader mit.

Band (`RibbonMesh`, gebaut in `RiverRibbonRenderer.build`/`emitRibbon`):
- `COLOR.rg` = Fließrichtung (kodiert ·0,5 + 0,5), `COLOR.b` = Strahler-Rang/6, `COLOR.a` = Deckkraft (Abfluss-Rampe × Kanal-Kohärenz × Taper). Stillwasser (Altarm, `still`) kodiert die Fließrichtung als 0; daran erkennt der Shader Stillwasser (kein Strömungs-Schimmer).
- `UV.x` = Quer-Position 0…1 (Kanten-Feathering), `UV.y` = Bogenlänge (Welt), im Shader die Phase von Wellen und Strömung.
- `UV2.x` = Band-Typ (`WaterRender.ribbonKind*`: Fluss, Delta-Arm, Altarm), `UV2.y` = signierte Bogenstärke −1…+1 (Querprofil, Prallhang tief; 0 auf Delta- und Altarmen; Issue #174 C2). Die Bogenstärke kommt aus `MeanderState.bendStrength`, also derselben Größe, mit der die Sim im Gürtel-Stempel den Kolk nach außen legt.
- `CUSTOM0` = `flows` (Look-Iteration 14): x = Riffel (0 Kolk…1 Riffel), y = Weißwasser (0…1), z = Gefälle (0…1 über `WaterRender.ribbonSlopeLo/Hi`), w = gemalte Bandbreite (Welt). Herleitung: `flowAttributes`.
- `CUSTOM1` = `profile` (Look E, #239): x = Korridor-Anteil 0…1 (1 = Ufer und Bett liegen als Geometrie darunter, das Band deckt den Wasserkörper bis zu deren Uferlinie mit der gemeinsamen Deckkraft-Rampe), y = Deckel-Höhe (Welt-Y), z = Halbbreite des Wassers (Welt), w = reserviert (0). Ohne Korridor ist y die eigene Höhe des Vertex; die Tiefe bleibt dann unverschoben (`corridor_clip`).
- `stripStarts` markiert den ersten Vertex jedes Bands. Godot braucht ihn nicht; die Wächter (`ribbon_strip_starts`) prüfen damit Band-Enden direkt, statt sie aus mehrdeutigen UV-Werten herzuleiten.

Korridor (`RiverCorridorMesh`):
- `COLOR.rg` = Band-Tangente (·0,5 + 0,5), `b` = Strahler-Rang/6, `a` = Deckkraft.
- `UV.x` = Querlage −1…+1, je Seite auf ±1 am EIGENEN Fuß normiert (Review Neon Nr. 8: der Shader blendet an beiden Kanten ins Gelände); `UV.y` = Bogenlänge (Welt).
- `UV2.x` = signierte Bogenstärke (wie `RibbonMesh.uv2s.y`), `UV2.y` = Gleithang-Anteil 0…1 (Kiesbank) dieses Vertex.
- `CUSTOM0` = x Tiefe unter dem Wasserspiegel (Welt-Y, negativ über Wasser), y Deckel-Höhe (Welt-Y), z Querversatz zur Zentrumslinie (Welt, signiert), w Halbbreite des Wassers (Welt).

Vorzeichen: Bei `bend > 0` liegt der Prallhang links (negative Querlage); das entspricht `outward` in `water.gdshader`.

Betrifft: `RibbonMesh`, `RiverCorridorMesh`, `RiverRibbonRenderer.build`, `RiverRibbonRenderer.emitRibbon`, `CorridorBandBuilder.emit`, `CorridorProfile.section`, `game/shaders/water.gdshader`, `game/shaders/corridor.gdshaderinc`, `game/tests/river_ribbons.gd`
