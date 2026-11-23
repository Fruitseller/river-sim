# Werkzeug-Tabelle als einziger Vertrag mit BrushTool

Eine Tabelle (`Main.TOOLS`, Issue #53) trägt Beschriftung, Icon, Brush-Modus und Verhalten jedes Werkzeugs. `mode` ist der Rohwert von `BrushTool` in SimCore (#79); über die Brücke geht nur diese Zahl, also müssen beide Reihenfolgen übereinstimmen (Wächter `SimCoreTests/ToolContractTests.swift`). Die Taste ist die Tabellen-Position (1…N), keine dritte Kopie. Ein neues Werkzeug ist eine Zeile hier plus ein `case` in `BrushTool`.

Pflichtfelder: `name`, `mode`, `icon` (gezeichnetes Icon aus `UiIcon.gd`, #174). Optionale Felder ersetzen je eine vorher verstreute Magie-Zahl:
- `shift`: Werkzeug, auf das Shift umschaltet (Anheben ↔ Absenken).
- `samples_target`: braucht die Geländehöhe am Strich-Beginn (Einebnen).
- `stroke_spacing`: zeichnet Einzelhiebe entlang des Strichs, Abstand in Zellen (Spitzhacke: auf der Stelle verharren gräbt nicht tiefer).
- `strength_factor`: Faktor auf die Pinselstärke (Spitzhacke schlägt kräftiger).
- `radius_capped`: echte Breite ist auf `pick_radius_cap` gedeckelt (Kuppel).
- `falloff_power`: Exponent p des Pinselgewichts (1 − d²)^p für die Kuppel, Standard `BRUSH_FALLOFF_POWER`.

Die Werkzeug-Knöpfe werden per Taste über den Setter `button_pressed` gedrückt, nicht über `set_pressed_no_signal`: nur der Setter löst den vorher aktiven Knopf der ButtonGroup, sonst leuchteten zwei.

Betrifft: `Main.TOOLS`, `Main._input`, `BrushTool`, `SimCoreTests/ToolContractTests.swift`, `game/tests/ui_layout.gd`
