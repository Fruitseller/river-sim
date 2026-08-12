import Foundation
import SimCore

// Mess-Harness für Issue #43 („erst messen, dann schrauben").
//
// Läuft die PRODUKTIONS-Konfiguration headless: dieselben Schalter, die
// `SimNode.productionConfig()` setzt (die Extension ist von SimCore aus nicht
// erreichbar, deshalb hier nachgebaut — die zwei Zeilen sind der ganze
// Unterschied zu `SimConfig()`; s. AGENTS.md „Drei Konfigurations-Ebenen").
//
// Zwei Betriebsarten, beide mit Einlauf (`--warmup`), damit gemessen wird, was
// die Sim im eingeschwungenen Zustand kostet und nicht der Kaltstart:
//
//   swift run -c release simperf                 # Zeiten, dt = 100
//   swift run -c release simperf --dt 0.2 --steps 200
//   swift run -c release simperf --hash          # Bit-Identitäts-Fingerabdruck
//
// `--hash` ist der Wächter für „Physik unverändert": ein FNV-1a über die
// Bit-Muster aller Zustandsfelder. Vor und nach einer Optimierung derselbe
// Wert ⇒ die Optimierung ist ergebnis-neutral. Er ist maschinen-spezifisch
// (System-libm, s. AGENTS.md) — verglichen wird immer auf DERSELBEN Maschine.

// MARK: - Argumente

func arg(_ name: String, _ fallback: Double) -> Double {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count,
          let v = Double(CommandLine.arguments[i + 1]) else { return fallback }
    return v
}
let flag = { (name: String) in CommandLine.arguments.contains(name) }

let gridN = Int(arg("--n", 832))
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

var cfg = SimConfig()
cfg.n = gridN
cfg.hydraulicSkipWaterSpawns = true
cfg.meanderSpatialCutoffIndex = true

// MARK: - Fingerabdruck

/// FNV-1a über die Roh-Bits — empfindlich auf jedes einzelne ulp.
func fnv(_ values: [Double], into hash: inout UInt64) {
    for v in values {
        var bits = v.bitPattern
        for _ in 0..<8 {
            hash = (hash ^ (bits & 0xFF)) &* 0x100_0000_01B3
            bits >>= 8
        }
    }
}

func fingerprint(_ t: Terrain) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    // Höhen, Füllhöhen, Abfluss (D8 + MFD), Sediment, Vegetation, Schnee, Eis:
    // die Felder, an denen jede Physik-Abweichung sichtbar wird.
    fnv(t.h, into: &hash)
    fnv(t.hf, into: &hash)
    fnv(t.area, into: &hash)
    fnv(t.areaMFD, into: &hash)
    fnv(t.sed, into: &hash)
    fnv(t.veg, into: &hash)
    fnv(t.snow, into: &hash)
    fnv(t.ice, into: &hash)
    return String(format: "%016llx", hash)
}

// MARK: - Lauf

let terrain = Terrain(config: cfg, seed: seed)
terrain.generate(seed: seed)

let genClock = Date()
for _ in 0..<warmupSteps { terrain.step(dtYears: warmupDt) }
let warmupSecs = -genClock.timeIntervalSinceNow

if hashMode {
    // Nach dem Einlauf noch die Messschritte, damit der Fingerabdruck denselben
    // Pfad abdeckt wie der Zeitlauf (inkl. Mäander/Braiding im eingeschwungenen
    // Zustand).
    for _ in 0..<steps { terrain.step(dtYears: dt) }
    print("n=\(gridN) seed=\(seed) warmup=\(warmupSteps)x\(warmupDt) steps=\(steps)x\(dt)")
    print("fingerprint \(fingerprint(terrain))")
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
    print("n=\(gridN) seed=\(seed) OHNE Profiling → \(String(format: "%.1f", perStep)) ms/Schritt")
    exit(0)
}
print("n=\(gridN) seed=\(seed) warmup=\(warmupSteps)x\(warmupDt)y (\(String(format: "%.1f", warmupSecs))s)")
print("Messung: \(steps) Schritte à dt=\(dt) → \(String(format: "%.1f", perStep)) ms/Schritt "
      + "(gesamt \(String(format: "%.2f", total))s)")
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
