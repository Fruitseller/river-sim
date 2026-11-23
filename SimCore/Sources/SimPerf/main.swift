import Foundation
import SimCore

func arg(_ name: String, _ fallback: Double) -> Double {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count,
          let v = Double(CommandLine.arguments[i + 1]) else { return fallback }
    return v
}
let flag = { (name: String) in CommandLine.arguments.contains(name) }

let production = SimConfig.production
if flag("--n") != flag("--world") {
    FileHandle.standardError.write(Data("""
        simperf: `--n` und `--world` gehören zusammen, gesetzt ist nur einer.
        Sie legen gemeinsam die Zellgröße fest; allein verstellt misst der Lauf
        eine andere Physik statt dasselbe Modell auf einem anderen Gitter.
          Produktion (Standard, aus SimConfig.production):  --n \(production.n) --world \(production.world)
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
let noProfile = flag("--no-profile")
let repeats = Int(arg("--repeat", 1))

var cfg = production
cfg.n = gridN
cfg.world = worldSize
if flag("--no-avalanche") { cfg.iceAvalancheSlopeHi = 0 }

let terrain = Terrain(config: cfg, seed: seed)

let warmupClock = Date()
for _ in 0..<warmupSteps { terrain.step(dtYears: warmupDt) }
let warmupSecs = -warmupClock.timeIntervalSinceNow

if hashMode {
    for _ in 0..<steps { terrain.step(dtYears: dt) }
    print("n=\(gridN) world=\(worldSize) seed=\(seed) "
          + "warmup=\(warmupSteps)x\(warmupDt) steps=\(steps)x\(dt)")
    print("fingerprint \(String(format: "%016llx", terrain.fingerprint()))")
    exit(0)
}

var blocks: [Double] = []
SimProfile.enabled = !noProfile
for r in 0..<repeats {
    if r == repeats - 1 { SimProfile.reset() }
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
print("Messung: \(steps) Schritte à dt=\(dt) → \(String(format: "%.1f", perStep)) ms/Schritt"
      + (repeats > 1 ? " (Minimum aus \(repeats) Blöcken)" : ""))
print("Tabelle: letzter Block, \(String(format: "%.2f", total))s")
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
