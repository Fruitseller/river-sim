# Kalibrierwerte kommen über das Register der Brücke, nicht als Kopie in GDScript

Alle Kalibrierwerte, die die Godot-Seite braucht, kommen über das Kalibrier-Register (Issue #213): `SimNode.calibration(group)` liefert Name → Wert einer Gruppe (`water`, `water_contract`, `relief`, `canopy`, `material`, `contract`) aus `SimRender.CalibrationRegistry`; die Zahlen stehen in den SimCore-Verträgen. `Main.calibration` und `Main.apply_calibration` sind statisch, damit die Godot-Wächter dieselbe Funktion headless benutzen.

`apply_calibration` setzt jeden Wert einer Uniform-Gruppe als gleichnamige Shader-Uniform auf jedes übergebene Material. Einen undeklarierten Namen ignoriert Godot still; welcher Shader was deklariert, prüfen deshalb `SimCoreTests/CalibrationRegistryTests.swift` und die Godot-Wächter (`water_uniforms.gd`, `relief.gd`, `canopy.gd`).

Die Höhen-Skalierung `hscale` (`RenderContract.heightScale`) kommt so in `_ready` über die Gruppe `contract` und ist bis dahin 0. Bis #213 stand sie in `Main.gd` als kopiertes Literal; nur der `hscale`-Default in `terrain.gdshader` bleibt als Kopie für die Editor-Vorschau ohne SimNode.

Betrifft: `Main.calibration`, `Main.apply_calibration`, `Main.hscale`, `SimRender.CalibrationRegistry`
