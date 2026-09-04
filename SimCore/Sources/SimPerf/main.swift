import Foundation
import SimCore

// Mess-Harness für Issue #43 („erst messen, dann schrauben").
//
// Läuft die PRODUKTIONS-Konfiguration headless: dieselben Schalter, die
// `SimNode.productionConfig()` setzt (die Extension ist von SimCore aus nicht
// erreichbar, deshalb hier nachgebaut — die zwei Zeilen sind der ganze
// Unterschied zu `SimConfig()`; s. AGENTS.md „Drei Konfigurations-Ebenen").
// Die CONFIG ist damit die der Produktion, der EINLAUF bewusst nicht — s.
// „Abweichung zur Produktion" unten am `Terrain`-Aufruf.
//
// Zwei Betriebsarten, beide mit Einlauf (`--warmup`), damit gemessen wird, was
// die Sim im eingeschwungenen Zustand kostet und nicht der Kaltstart:
//
//   swift build -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5
//   SimCore/.build/release/simperf                      # Zeiten, dt = 100
//   SimCore/.build/release/simperf --repeat 3           # drei Messblöcke
//   SimCore/.build/release/simperf --dt 0.2 --steps 200 # Echtzeit-Takt
//   SimCore/.build/release/simperf --hash               # Bit-Identität
//
// `--hash` ist der Wächter für „Physik unverändert": `Terrain.fingerprint()`
// über das komplette Zustands-Inventar (Issue #78; Semantik, Abdeckung und
// Grenzen: Doku an `TerrainState.fingerprint()` in WorldSnapshot.swift).
// Vor und nach einer Optimierung derselbe Wert ⇒ ergebnis-neutral; Werte von
// vor #78 (nur 8 Felder gehasht) sind mit heutigen nicht vergleichbar.

// MARK: - Argumente

func arg(_ name: String, _ fallback: Double) -> Double {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count,
          let v = Double(CommandLine.arguments[i + 1]) else { return fallback }
    return v
}
let flag = { (name: String) in CommandLine.arguments.contains(name) }

// Standard der Gitter-Paarung ist die PRODUKTIONS-Paarung aus `SimConfig()`
// selbst, nicht ein Literal: sie wurde schon einmal gemeinsam verstellt
// (832/130 → 720/112,4789, Aug 2026), und als Literal hätte der Harness danach
// still die alte, größere Welt weitergemessen — während `--hash` und die
// Pass-Tabelle behaupten, die Produktion zu spiegeln.
//
// `n` und `world` gehören ZUSAMMEN (AGENTS.md): allein verstellt, ändert `--n`
// die Zellgröße und damit jede per-Zell-Kalibrierung — der Lauf misst dann eine
// andere Physik, nicht dasselbe Modell auf kleinerem Gitter. Ältere Messreihen
// in `docs/perf-measurements.md` reproduziert man deshalb mit BEIDEN Schaltern
// (die Paarung davor: `--n 832 --world 130`).
let production = SimConfig()
// Genau EINEN der beiden Schalter zu setzen ist nie Absicht, sondern immer der
// Fehler „alte Gewohnheit, halb umgestellt": `--n 832` allein paart die alte
// Auflösung mit der neuen Weltgröße. Der Lauf misst dann eine Zellgröße, die es
// nirgends gibt, und die Kopfzeile sieht dabei völlig plausibel aus — der Fehler
// wäre also wieder still. Deshalb hier hart abbrechen statt weiterzurechnen.
if flag("--n") != flag("--world") {
    FileHandle.standardError.write(Data("""
        simperf: `--n` und `--world` gehören zusammen, gesetzt ist nur einer.
        Sie legen gemeinsam die Zellgröße fest; allein verstellt misst der Lauf
        eine andere Physik statt dasselbe Modell auf einem anderen Gitter.
          Produktion (Standard, aus SimConfig()):  --n \(production.n) --world \(production.world)
          Messreihen in docs/perf-measurements.md: --n 832 --world 130

        """.utf8))
    exit(2)
}
let gridN = Int(arg("--n", Double(production.n)))
let worldSize = arg("--world", production.world)
let seed = UInt32(arg("--seed", 1337))
let warmupSteps = Int(arg("--warmup", 100))
let warmupDt = arg("--warmup-dt", 100)
let dt = arg("--dt", 100)
let steps = Int(arg("--steps", 30))
let hashMode = flag("--hash")
// Gegenprobe für die Instrumentierung selbst: derselbe Lauf ohne Marken.
let noProfile = flag("--no-profile")
// Mehrere Messblöcke hintereinander: die VM streut zwischen Prozessläufen
// spürbar (CPU-Takt, Nachbarlast), innerhalb eines Laufs deutlich weniger.
// Entschieden wird nach dem MINIMUM — das ist der Lauf mit der wenigsten
// Fremdstörung, also die belastbarste Zahl für einen Vorher/Nachher-Vergleich.
let repeats = Int(arg("--repeat", 1))

// MARK: - Produktions-Config (Spiegel von SimNode.productionConfig())

var cfg = production
cfg.n = gridN
cfg.world = worldSize
cfg.hydraulicSkipWaterSpawns = true
cfg.meanderSpatialCutoffIndex = true

// MARK: - Lauf

// `Terrain(config:seed:)` GENERIERT bereits — der reine Allokations-Weg ist
// `init(allocating:)` und existiert nur für den Snapshot-Pfad. Der zusätzliche
// `generate`-Aufruf, der hier stand, war deshalb nicht nur doppelte Arbeit,
// sondern verstellte die Messwelt: `generate` leert `veg` NICHT, und der
// Sukzessions-Pass liest über den Samen-Druck (`vegDispersalRadius`) das
// VORHANDENE Feld. Ein zweiter Lauf startet also mit dem Samen-Druck des ersten
// (gemessen und gepinnt in `TerrainAPITests.testGenerateResetsAnAgedTerrain`).
// Der Harness misst damit eine Vegetation, die keine frisch generierte
// Produktionswelt hat — und `veg` ist über `vegDamp` an die Erosion gekoppelt,
// also nicht bloß Optik.
//
// ABWEICHUNG zur Produktion, bewusst: die Brücke generiert mit
// `settleYears: SimNode.generationSettleYears` (3000 J. echte Physik in
// 1000-Jahr-Chunks, Uhr danach zurück auf 0, danach die Startzustands-Doktrinen
// für Seespiegel und Playa-Kruste; PR #106). Hier bleibt `settleYears` beim
// Default 0, den Einlauf macht das `--warmup` — 100 × 100 J., also 10.000 Jahre
// und damit weiter eingeschwungen als die Produktionswelt, nur über einen
// anderen Pfad. Der Wert wird NICHT gespiegelt wie die zwei Perf-Flags: er
// würde die Messwelt verschieben und damit jede Zahl in
// `docs/perf-measurements.md` samt `--hash`-Fingerabdruck ein weiteres Mal
// unvergleichbar machen — der Harness vergleicht Vorher/Nachher auf DERSELBEN
// Maschine, und dafür zählt allein, dass beide Läufe dieselbe Welt fahren.
// Praktische Folge, damit sie nicht wieder Rätsel aufgibt: ein Fingerabdruck
// aus `--hash` und einer aus der Brücke gehören zu zwei verschiedenen Welten
// und sind nie gleich.
let terrain = Terrain(config: cfg, seed: seed)

let warmupClock = Date()
for _ in 0..<warmupSteps { terrain.step(dtYears: warmupDt) }
let warmupSecs = -warmupClock.timeIntervalSinceNow

if hashMode {
    // Nach dem Einlauf noch die Messschritte, damit der Fingerabdruck denselben
    // Pfad abdeckt wie der Zeitlauf (inkl. Mäander/Braiding im eingeschwungenen
    // Zustand).
    for _ in 0..<steps { terrain.step(dtYears: dt) }
    print("n=\(gridN) world=\(worldSize) seed=\(seed) "
          + "warmup=\(warmupSteps)x\(warmupDt) steps=\(steps)x\(dt)")
    print("fingerprint \(String(format: "%016llx", terrain.fingerprint()))")
    exit(0)
}

var blocks: [Double] = []
SimProfile.enabled = !noProfile
for r in 0..<repeats {
    if r == repeats - 1 { SimProfile.reset() } // Tabelle aus dem letzten Block
    let clock = Date()
    for _ in 0..<steps { terrain.step(dtYears: dt) }
    blocks.append(-clock.timeIntervalSinceNow)
}
SimProfile.enabled = false
let total = blocks.last!

let perStep = blocks.min()! / Double(steps) * 1000
if repeats > 1 {
    print("Blöcke (ms/Schritt): "
          + blocks.map { String(format: "%.1f", $0 / Double(steps) * 1000) }.joined(separator: " "))
}
if noProfile {
    print("n=\(gridN) world=\(worldSize) seed=\(seed) OHNE Profiling → "
          + "\(String(format: "%.1f", perStep)) ms/Schritt")
    exit(0)
}
print("n=\(gridN) world=\(worldSize) seed=\(seed) "
      + "warmup=\(warmupSteps)x\(warmupDt)y (\(String(format: "%.1f", warmupSecs))s)")
// Kennzahl ist das Block-MINIMUM (s. o.); die Pass-Tabelle darunter stammt
// dagegen aus dem LETZTEN Block — beide Zahlen also getrennt ausweisen.
print("Messung: \(steps) Schritte à dt=\(dt) → \(String(format: "%.1f", perStep)) ms/Schritt"
      + (repeats > 1 ? " (Minimum aus \(repeats) Blöcken)" : ""))
print("Tabelle: letzter Block, \(String(format: "%.2f", total))s")
// Größenordnung der Lagrange-Läufe: der Mäander-Aufwand hängt an den KNOTEN,
// nicht an der Gitterzelle — ohne die Zahl ist die Pass-Tabelle nicht deutbar.
let nodeCount = terrain.meander.channels.reduce(0) { $0 + $1.nodes.count }
print("Mäander: \(terrain.meander.channels.count) Läufe, \(nodeCount) Knoten, "
      + "\(terrain.meander.oxbows.count) Altarme")
print("")
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
func lpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}
print(pad("Pass", 24) + lpad("ms/Schritt", 11) + lpad("Anteil", 8) + lpad("Aufrufe", 9))
var accounted = 0.0
for row in SimProfile.report() {
    accounted += row.seconds
    print(pad(row.name, 24)
          + lpad(String(format: "%.2f", row.seconds / Double(steps) * 1000), 11)
          + lpad(String(format: "%.1f%%", row.seconds / total * 100), 8)
          + lpad("\(row.calls)", 9))
}
print(pad("— nicht zugeordnet —", 24)
      + lpad(String(format: "%.2f", (total - accounted) / Double(steps) * 1000), 11)
      + lpad(String(format: "%.1f%%", (total - accounted) / total * 100), 8))
