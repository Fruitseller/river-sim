# Godot-Tests holen Kalibrier- und Vertragswerte über die Brücke

Seit #92 bzw. #213 kopieren die Godot-Tests keine Kalibrier-Zahlen mehr. Sie holen sie über das Kalibrier-Register (`Main.calibration(sim, group)`), Gruppen `water_contract` und `contract` (Überhöhung, Band-Anhebung) für die Wasser-Wächter, `water` für die Uniforms. Die Paarung Name ↔ Swift-Konstante pinnt `SimCoreTests/CalibrationRegistryTests.swift` ausführbar; begründet sind die Werte in `SimCore/WaterRender.swift`.

`game/tests/water_uniforms.gd` (#91/#92) hält den Contract-Schritt: jede `water_*`-Uniform, die ein Shader deklariert, bekommt ihren Wert ausschließlich über die Brücke; keine bleibt still auf ihrem Default, keine trägt einen Literal-Default (das wäre wieder die Kopie, die #92 abschafft). Geprüft: Tabelle konsistent, jede deklarierte Uniform steht in der Tabelle und ist default-frei, jeder Tabellenwert ist in mindestens einem Shader deklariert, und `Main.apply_calibration` setzt jeden Namen wirklich (`get_shader_parameter` liefert den Brückenwert). Skalare reisen als float, Farben als Vector3. Ein doppelter Name überschriebe sich im Dictionary still; die Eindeutigkeit prüft deshalb die Swift-Seite.

Die Deklarationen werden mit einem Zeilenanker aus den Shader-Quelltexten gelesen; die strengere, kommentarbereinigte Sicht hält `SimCoreTests` (`SourceProbe`). Der Uniform-Typ wird breit gematcht und dann geprüft, damit eine künftige `uniform vec2 water_*` laut scheitert statt still am Wächter vorbeizugehen.

Betrifft: `game/tests/water_uniforms.gd`, `game/tests/water_geometry.gd`, `game/tests/river_ribbons.gd`, `SimRender.CalibrationRegistry`, `Main.calibration`, `Main.apply_calibration`
