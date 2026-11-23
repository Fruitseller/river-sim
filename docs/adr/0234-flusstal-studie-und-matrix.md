# Flusstal-Studie und Abnahmematrix: feste Kameras, laute Fehler, Mac-taugliches Bash

Seit #152 sind alle Hebel der Studie #116 Produktion (#151, #153, #155, #152). Ein alter Aufruf mit `RS_STUDY_LEVERS` scheitert laut, statt still dasselbe Bild zu liefern (`game/tests/graphics_study.gd` prüft das).

Die Studien-Shader werden zur Laufzeit aus den Produktionsquellen gebaut (`#define FLUSSTAL_STUDY` vor der Quelle). Früher rutschte ein stiller Include-Fehler durch, weil nichts den zusammengesetzten Code kompilierte: das Material fiel auf Standard zurück, nur ein A/B-Bild hätte es gezeigt. Der Test parst deshalb beide Fassungen: Produktion darf die Studien-Uniforms nicht kennen, die Studie muss sie liefern; fehlen sie, ist es ein Kompilierungsfehler. Seit #174 D bleiben dafür nur die Debug-Ansichten (`study_debug`).

Abnahmematrix (`scripts/graphics-matrix.sh`, #150, Spec #156): die Matrix kommt ohne assoziative Arrays aus, weil macOS bash 3.2 liefert (Zielmaschine ist ein Mac) und `declare -A` dort mit Syntaxfehler abbrach. Kameras je Seed als `ziel;distanz;yaw;pitch`. Die Sonne ist seit #151 eine feste Welt-Sonne (Azimut −50°, `game/scripts/Lighting.gd`); `backlight` blickt mit Yaw = Azimut + 180° (130° = 2,269 rad) genau gegen sie. Die Tabelle ist in `SimCoreTests/GraphicsMatrixTests.swift` gespiegelt und gepinnt.

Vorlagen-Kameras (#174): diorama = Vorlage C, valley = B, close = A. In der Matrix stehen feste Werte je Seed (Ziel, Distanz, Yaw), damit Abnahmebilder reproduzierbar bleiben. Die Tasten-Presets F1–F3 (`Main.CAMERA_PRESETS`) sind adaptiv (Diorama rahmt die Landfläche, Tal/Nah zielen auf den größten Lauf). Gemeinsam sind nur Pitch (alle) und Distanz (valley, close); Wächter `GraphicsMatrixTests.testCameraPresetsMatchTheMatrix`. Die adaptive Ansicht zeigt `RS_CAMERA=<id>`.

Timing-Ergebnisse landen als Datei neben den Aufnahmen (Spec #156): eine JSON-Zeile je Lauf mit Viewport, Qualitätsstufe und Render-Gitter; der Dateiname trägt Welt, Stadium, Kamera, Stufe und Betrieb.

Video-Aufnahme der Studie: die Encoder-Größe kommt aus den `.movie`-Viewport-Overrides in `project.godot`; der MovieWriter öffnet den Encoder vor dem Maximieren und ignoriert dafür `--resolution` (gemessen an Godot 4.7.2). `--resolution` setzt nur das Fenster-Vorabmaß vor `--maximized`.

Betrifft: `game/tests/graphics_study.gd`, `game/studies/flusstal/Flusstal.gd`, `scripts/graphics-matrix.sh` (`camera_cfg`), `scripts/graphics-study.sh`, `SimCoreTests/GraphicsMatrixTests.swift`
