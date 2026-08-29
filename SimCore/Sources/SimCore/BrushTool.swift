/// Werkzeug-Modi des Pinsels — der EINE Vertrag „Zahl → Terrain-Operation"
/// zwischen Game-Layer und Sim (Issue #53; seit #79 hier in SimCore).
///
/// Vorher stand die Zuordnung „Zahl → Terrain-Operation" als `switch` über nackte
/// Ints in der Brücke und die Zahlen selbst verstreut im Game-Layer (Tool-Index
/// der Button-Tabelle, `current_tool == 3` fürs Einebnen-Ziel, `mode == 5` für den
/// Spitzhacken-Strich, Tastatur-Offset). Ein neues Werkzeug hieß: fünf Stellen
/// finden. Jetzt ist es EINE Zeile in `Main.gd`s Werkzeug-Tabelle und EIN `case`
/// hier — beide in derselben Reihenfolge, weil GDScript nur die Zahl übergeben
/// kann.
///
/// Liegt seit Issue #79 in SimCore, nicht in der Extension: der Typ hängt nur an
/// `Terrain`, und hier ist er headless AUSFÜHRBAR — `ToolContractTests` prüft die
/// Rohwerte gegen die Tabelle in `Main.gd` und das Routing jedes `case` als
/// Verhaltens-Test auf einem echten Terrain (statt wie früher per
/// Quelltext-Parsing des `switch` in der Brücke).
public enum BrushTool: Int, CaseIterable {
    case raise = 0
    case lower = 1
    case smooth = 2
    /// Einebnen auf `target` (die Höhe am Strich-Beginn).
    case flatten = 3
    /// Aufrauen mit fraktalem Rauschen.
    case roughen = 4
    /// Spitzhacke: tieferer, spitzer Hieb — leitet Flüsse um.
    case pickaxe = 5

    /// Führt den Hieb auf dem Terrain aus. `target` gilt nur fürs Einebnen; die
    /// übrigen Werkzeuge ignorieren ihn (Godot kann keine optionalen Argumente
    /// über die Brücke schicken, deshalb EIN Signatur-Satz für alle).
    public func apply(to terrain: Terrain, gx: Double, gz: Double, radiusWorld: Double,
                      strength: Double, target: Double) {
        switch self {
        case .raise:
            terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: 1, strength: strength)
        case .lower:
            terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: -1, strength: strength)
        case .smooth:
            terrain.smooth(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        case .flatten:
            terrain.flatten(gx: gx, gz: gz, radiusWorld: radiusWorld,
                            targetHeight: target, strength: strength)
        case .roughen:
            terrain.roughen(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        case .pickaxe:
            terrain.pickaxe(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        }
    }
}
