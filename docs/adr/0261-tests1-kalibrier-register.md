# Kalibrier-Register: Namen in Gruppen, Zahlen nur in den SimCore-Verträgen

Das Register der Brücke (#213) vergibt nur Namen; die Zahlen stehen in `WaterRender`, `ReliefRender`, `CanopyRender`, `MaterialRender` und `RenderContract`. Gepinnt wird ein einziger Name-Wert-Spiegel über alle Gruppen, vollständig und in beide Richtungen (ein Eintrag mit eigener Zahl, vertauschten Konstanten oder ohne Spiegel-Zeile fällt auf), dazu Präfixe und Eindeutigkeit der Namen.

Regeln:
- Alle Uniform-Gruppen landen auf denselben Materialien (das Terrain liest vier davon). Der Gruppen-Präfix hält sie auseinander und von den übrigen Uniforms (`hscale`, `sea_level`, …) fern.
- Shader deklarieren Kalibrier-Uniforms default-frei; ein Literal-Default wäre wieder eine Kopie der Kalibrierung (#92). Jede Deklaration muss mindestens einmal gelesen werden, gezählt als ganzer Bezeichner (Review zu #105). Der Wächter matcht den Uniform-Typ breit und prüft dann, damit etwa eine künftige `uniform vec2 water_*` laut scheitert statt still am Wächter vorbei. Texturen und Schalter (`sampler*`, `bool`) sind keine Kalibrier-Zahlen. Kein Shader darf eine Kalibrier-Uniform am Register vorbei deklarieren.
- Die GDExtension bleibt reines Marshalling: ein Callable `calibration(group:)` für alle Gruppen statt zwei je Tabelle, keine eigenen Namen oder Zahlen. `Main.gd` hat eine Lese- und eine Anwendungsfunktion.
- Bis #213 standen Überhöhung und Band-Anhebung als Literale in `Main.gd` (`HSCALE`, `RIVER_LIFT`), von Grep-Wächtern auf die Zahl gehalten. Jetzt holt GDScript sie aus der Gruppe `contract`. Seit #214 fahren die Godot-Werkzeuge den Frame: wer die Werte selbst braucht (`river_ribbons.gd` rechnet die Band-Höhen nach), holt sie über die Brücke; für die übrigen bleibt „keine Kopie" als ganzer Vertrag. Die Godot-Wasser-Wächter prüfen gegen die Gruppe `water_contract`.

Wo welcher Wert gelesen wird, pinnen `WaterUniformsTests` und `ReliefUniformsTests`; dass die Werte in Godot ankommen, `game/tests/water_uniforms.gd`, `relief.gd` und `canopy.gd`.

Betrifft: `SimRender.CalibrationRegistry`, `SimNode.calibration`, `Main.calibration`, `Main.apply_calibration`, `CalibrationRegistryTests`
