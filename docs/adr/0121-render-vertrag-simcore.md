# Render-Kalibrierung als headless prüfbarer Vertrag in SimCore

Zahlen, die mehrere Schichten (Godot-Seite in `game/`, GDExtension, Shader, SimRender) gemeinsam annehmen müssen, stehen an EINER Stelle im Target `SimCore`: `RenderContract` für Welt-Annahmen, `WaterRender` für die Wasser-Kalibrierung, `Strahler` für die Rang-Ableitung. Das ist eine bewusste Ausnahme von „SimCore = Physik“: die Typen haben keinen Sim-Zustand und ändern keine Physik, sie entscheiden nur, was gemalt wird. Grund: die Zahlen hängen paarweise zusammen (Komponentengröße ↔ Shader-Smoothstep ↔ Altarm-Stempel) und standen vorher verstreut in der GDExtension (nur mit einem ~20-Minuten-Build prüfbar) und im Shader (überhaupt nicht prüfbar). In SimCore sind sie headless testbar.

Bis Issue #51 standen auch die Zahlen des Raster-Wasserfelds (Track-Maske, Abstufung, Verbreiterung) als Literale in `SimNode.waterFieldBytes`; sie sind seitdem Teil des Vertrags und in `SimCoreTests/WaterRenderTests.swift` gepinnt.

Gefundene Drift, die der Vertrag beendet hat (Issue #51):
- `hscale`: `Main.gd` setzte 24.0, `terrain.gdshader` hatte als Default 26.0. Sichtbar nur, wenn der Shader ohne gesetzte Uniform lief (Editor-Vorschau, Material ohne `SimNode`); dann war das ganze Terrain 8 % zu hoch. Der `hscale`-Default im Terrain-Shader bleibt als einzige gepinnte Shader-Zahl stehen.
- Start-Seed: `Main.gd` und der Terrain-Default der GDExtension legten 1337 doppelt fest; angezeigter Seed und gezeigte Welt hätten sich lautlos trennen können.

`heightScale` (Sim-Höhe 0…1 × `heightScale` = Godot-Welt-Y) wurde von 30 auf 24 gesenkt: weniger vertikale Überhöhung, sanfterer Look, ergänzt das gesenkte `baseRelief`. Leser: `Main.gd` (Mesh, Kamera-Sampling, Bänder), `terrain.gdshader` (Displacement, Normalen), der Band-Bau in `RenderState` (bekommt ihn als Parameter, legt ihn nicht selbst fest) und die Waldmaske (`ForestCanopyMask`, Steilwand-Schwelle in Weltsteigung).

Die Shader-Stellen, die die Wasser-Kalibrierung lesen, sind in `WaterRender` als reine Funktionen nachgebaut (`riverMask`, `lakeGate`, `lakeMask`, `shore`), damit Regressionen wie „Saum ohne Wasser“ headless prüfbar sind statt nur auf der GPU. Die Zahlen reisen als Uniforms zum Shader (Gruppe `water` im `SimRender.CalibrationRegistry`, #91/#92/#213); der Struktur-Vertrag in `WaterRenderTests` hält fest, welche Shader-Stelle welches Fenster liest. Wächter für `RenderContract`: `SimCoreTests/RenderContractTests.swift` gegen die echten Quelltexte von `Main.gd` und den Shadern.

Betrifft: `RenderContract`, `RenderContract.heightScale`, `RenderContract.defaultSeed`, `WaterRender`, `WaterRender.riverMask`, `WaterRender.shore`, `SimRender.CalibrationRegistry`, `SimCoreTests/RenderContractTests.swift`, `SimCoreTests/WaterRenderTests.swift`
