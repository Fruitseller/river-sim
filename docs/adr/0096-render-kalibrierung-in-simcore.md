# Render-Kalibrierungen in SimCore: WO auf der CPU, WIE im Shader

`CanopyRender`, `MaterialRender` und `ReliefRender` sind reine Render-Ableitungen ohne Sim-Zustand: nichts darin ändert Physik, `simperf --hash` bleibt gleich. Jede Kalibrierung zerfällt in zwei Hälften mit getrennten Lesern, damit die Lage-Entscheidungen deterministisch und headless prüfbar bleiben und der Shader nur das Aussehen baut.

- WO etwas liegt (Wald, Fels, Schutt, Eis, Rohboden, Talboden), rechnet SimRender auf der CPU einmal je Terrain-Update als Gewicht je Sim-Zelle: `SimRender.ForestCanopyMask` für den Wald (Vegetation, Steigung, Schnee/Eis, Küste, Lichtungen, Schutzmaske), `SimRender.TerrainColorRenderer` für die Materialien (`surfaces`, `covers`). Diese Schwellen erreichen keinen Shader.
- WIE es aussieht (Kronengröße, Dachhöhe, Ausdünnen am Rand, Ausblenden in der Entfernung, Klüftung, Spalten, Moränen, Feinverteilung an Rinnen und Rippen), rechnet `game/shaders/terrain.gdshader` je Pixel. Diese Zahlen reisen über `SimRender.CalibrationRegistry` (Gruppen `canopy`, `material`, `relief`) → `SimNode` → `Main.gd` und stehen default-frei im Shader (Muster #92), nie als Kopie.

Die Render-Verschiebung von Rinnen und Graten (#153) rechnet die GPU (`game/shaders/relief_bake.gdshader`) einmal je Terrain-Update in eine Textur; der Terrain-Shader liest daraus Höhe (Vertex), Steigung und Rinnen-Schattierung (Pixel). Seit #238 liefert diese Textur mit RenderingDevice die Gelände-Verfeinerung (`TerrainAmplifier.gd`), der Back-Pass bleibt der Rückfall.

Steigungen in diesen Kalibrierungen sind Weltsteigungen (dy/dx in Welteinheiten, mit `RenderContract.heightScale`), gemessen über `Terrain.macroSlope` (±2 Zellen, die eine Quelle der Makro-Steigung) und umgerechnet wie in `ForestCanopyMask`; damit sind die Winkel dieselben, die man im Bild sieht. Weltmaßstab: 1 Einheit ≈ 100 m.

Herkunft: Kronendach und Relief stammen aus der Flusstal-Studie #116 (Hebel `canopy` bzw. `geometry`), vom Projekteigner mit PR #121 abgenommen (`docs/graphics-quality.md`). Die Studie rechnete die Waldmaske im Shader; die Schwellen sind dieselben. Das Kronendach war ursprünglich kein Instanz-Modell, sondern eine Schicht im Terrain-Shader (angehobenes Dach mit Einzelkronen, Lücken, Lichtungen); seit #236 stehen mit RenderingDevice Einzelbäume (`ForestTrees.gd`) darauf, ohne RenderingDevice bleibt es beim Dach.

Ausnahme: Fels und Schutt kommen seit #237 aus gescannten CC0-Materialien (`game/shaders/scan_material.gdshaderinc`). Deren Maßstäbe sind Geschmackswerte neben dem Shader-Code, keine Kalibrierung; die früheren `joint*`- und `screeGrain`-Werte sind deshalb aus `MaterialRender` entfallen.

Wächter: `SimCoreTests/CanopyTests.swift`, `SimCoreTests/MaterialTests.swift` (Flächenanteile auf den Matrix-Welten: `testMaterialCoverageDiagnostic`, `docs/graphics-quality.md` § Material, Schnee, Wolken), `SimCoreTests/ReliefUniformsTests.swift`, End-to-End `game/tests/relief.gd`.

Betrifft: `CanopyRender`, `MaterialRender`, `ReliefRender`, `SimRender.ForestCanopyMask`, `SimRender.TerrainColorRenderer`, `SimRender.CalibrationRegistry`, `game/shaders/terrain.gdshader`, `game/shaders/relief_bake.gdshader`
