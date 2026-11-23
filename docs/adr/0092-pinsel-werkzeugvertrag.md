# Pinsel-Werkzeuge als ein Vertrag „Zahl → Terrain-Operation" in SimCore

`BrushTool` ist der eine Vertrag zwischen Game-Layer und Sim (Issue #53, seit #79 in SimCore). Vorher stand die Zuordnung als `switch` über nackte Ints in der Brücke und die Zahlen verstreut im Game-Layer (Tool-Index der Button-Tabelle, `current_tool == 3` fürs Einebnen-Ziel, `mode == 5` für den Spitzhacken-Strich, Tastatur-Offset); ein neues Werkzeug hieß fünf Stellen finden. Jetzt ist es eine Zeile in `Main.gd`s Werkzeug-Tabelle und ein `case` hier, beide in derselben Reihenfolge, weil GDScript nur die Zahl übergeben kann.

Der Typ liegt in SimCore statt in der Extension, weil er nur an `Terrain` hängt und hier headless ausführbar ist: `ToolContractTests` prüft die Rohwerte gegen die Tabelle in `Main.gd` und das Routing jedes `case` als Verhaltens-Test auf einem echten Terrain (statt wie früher per Quelltext-Parsing des `switch` in der Brücke).

`apply` hat EINEN Signatur-Satz für alle Werkzeuge, weil Godot keine optionalen Argumente über die Brücke schicken kann; `target` (Höhe am Strich-Beginn) gilt nur fürs Einebnen, die übrigen ignorieren ihn. Nicht-endliche Parameter führen bei allen Werkzeugen zum No-op.

Betrifft: `BrushTool`, `BrushTool.apply`, `SimNode.brush`, `game/scripts/Main.gd` (Werkzeug-Tabelle), `ToolContractTests`
