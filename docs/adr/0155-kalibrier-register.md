# Ein Kalibrier-Register für alle Werte der Godot-Seite

`SimRender.CalibrationRegistry` ist das eine Register der Brücke (Issue #213): benannte Werte in Gruppen, die alle denselben Weg nehmen (`SimNode.calibration(group)` → `Main.calibration`/`Main.apply_calibration`). Es ersetzte die vier gleich gebauten Tabellen `WaterUniforms`, `ReliefUniforms`, `CanopyUniforms` und `MaterialUniforms` samt ihrer zwölf Callables.

Das Register vergibt nur NAMEN. Die Zahlen bleiben in den SimCore-Verträgen (`WaterRender`, `ReliefRender`, `CanopyRender`, `MaterialRender`, `RenderContract`); eine eigene Zahl hier wäre wieder die Kopie, die #51/#92 abgeschafft haben. Zwei Konstanten (`pondContourLo`, `ribbonDeltaLo`) speisen zugleich eine Vertragsgruppe und eine gleichnamige Uniform in `water`; beide Zeilen lesen dieselbe Konstante.

Zwei Arten von Gruppen (`Group.isUniform`):
- Uniform-Gruppen (`water`, `relief`, `canopy`, `material`): jeder Name trägt den Gruppen-Präfix und setzt eine gleichnamige Shader-Uniform. Die Shader deklarieren sie ohne Default (#92); die Editor-Vorschau ohne SimNode ist bewusst unkalibriert (alles Null). Damit das nur unkalibriert und nicht undefiniert heißt, klemmen die Wasser-Shader Fenster, Divisionen und den Fresnel-Exponenten per Epsilon (`calib_window`/`max`, Review zu #105), gepinnt in `WaterRenderTests`. Über die Brücke werden diese Werte auf Float32 verengt: GLSL-Uniforms sind ohnehin einfach genau, und GDScript rechnet mit genau dem Wert, den der Shader sieht.
- Vertragsgruppen (`water_contract`, `contract`): keine Uniforms, sondern Zahlen, die GDScript selbst braucht (Godot-Wasser-Wächter `water_geometry.gd`/`river_ribbons.gd`, Überhöhung, Band-Anhebung). Die Namen sind die Swift-Bezeichner, damit die Paarung lesbar bleibt. Sie bleiben Double, damit die Godot-Wächter exakt die Kalibrierung vergleichen. Ints wie `mouthSearchCells` reisen als Double, GDScript castet zurück. Überhöhung und Band-Anhebung standen bis #213 als kopierte Literale (`HSCALE`, `RIVER_LIFT`) in `Main.gd`, nur von Grep-Wächtern synchron gehalten.

Skalare reisen als `float`, Farben als `Vector3`, in Deklarationsreihenfolge. Eine unbekannte Gruppe liefert ein leeres Dictionary; `Main.calibration` meldet das laut.

Nicht ins Register gehören Werte, die CPU-seitig wirken: die Schwellen der Waldmaske (`ForestCanopyMask`) und die Verteilung von Fels, Halde, Eis und Rohboden (`TerrainColorRenderer`).

Ausnahme: Der `hscale`-Default im Terrain-Shader bleibt als gepinnte Kopie stehen (Editor-Vorschau ohne SimNode); s. Issue-Entwurf #269.

Wächter: `SimCoreTests/CalibrationRegistryTests.swift` (Name-Wert-Spiegel, Präfixe, default-freie Deklarationen, Brücke, `Main.gd`) und End-to-End `game/tests/water_uniforms.gd`, `relief.gd`, `canopy.gd`.

Betrifft: `CalibrationRegistry`, `CalibrationRegistry.Group.isUniform`, `SimNode.calibration`, `Main.calibration`, `Main.apply_calibration`, `RenderContract.heightScale`, `RenderContract.riverLift`
