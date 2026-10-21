import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Messreihe zu Issue #174, Abnahmepunkt 26 („≥ 1 Delta mit ≥ 3 Distributären
/// und Sandinseln"): warum an den großen Mündungen keine Deltaebene über dem
/// Meeresspiegel entsteht, und ob sie es jetzt tut. Tabellen:
/// `docs/zielbild-measurements.md` § Delta.
///
///     RS_MEASURE=1 RS_CACHE=/tmp/delta-welten swift test -c release --package-path SimCore \
///         --filter testDeltaBudgetDiagnostic
///
/// `RS_SEEDS` (Komma-Liste), `RS_YEARS_LIST` (Komma-Liste), `RS_CACHE` (Ordner
/// für gealterte Welten), `RS_OUT` (Ordner für Draufsicht-PPMs der Mündungen),
/// `RS_DT` (Schrittweite der Alterung, Standard 1000 wie `RS_STEP`),
/// `RS_DELTA` (Varianten, s. `DeltaMetrics.variantConfig`), `RS_BUDGET=1`
/// (Pass-Bilanz über 1000 Jahre, Schrittweite `RS_BUDGET_DT`). Die Welten
/// sind dieselben wie im Spiel (`RS_SEED` + `RS_STEP` in 1000er-Schritten):
/// `generate` auf einem benutzten Terrain liefert seit caed8b5 die frische
/// Welt.
final class RiverDeltaTests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment

    func testDeltaBudgetDiagnostic() throws {
        try skipUnlessMeasuring()
        let seeds = (env["RS_SEEDS"] ?? "1337,42,20").split(separator: ",").compactMap { UInt32($0) }
        let years = (env["RS_YEARS_LIST"] ?? "2000,20000,100000").split(separator: ",").compactMap { Double($0) }
        for seed in seeds {
            for year in years {
                let t = try DeltaMetrics.world(seed: seed, year: year, env: env)
                t.computeFlow()
                let mouths = DeltaMetrics.bigMouths(t)
                let colors = TerrainColorRenderer.buffers(t).colors
                let sand = (0..<t.cfg.count).map { colors[$0 * 4 + 3] >= 128 }
                print("\n=== DELTA s\(seed) J\(Int(year)): \(mouths.count) Mündungen ≥ \(Int(DeltaMetrics.bigMouthCells)) Zellen ===")
                var best: (arms: Int, islands: Int, cells: Int, sand: Double, q: Double) = (0, 0, 0, 0, 0)
                var lagoons = 0
                for m in mouths {
                    let s = DeltaMetrics.shape(t, m, sand: sand)
                    if (s.arms, s.islandCells) > (best.arms, best.cells) {
                        best = (s.arms, s.islands, s.islandCells, s.islandSand, m.discharge)
                    }
                    print(String(format: "MOUTH s%d J%d q=%6.0f @(%d,%d) | Ebene sea..+0.002: %d, +0.002..+0.006: %d | Schelf <0.005: %d, <0.015: %d, <0.03: %d, tiefer: %d | Arme %d, Inseln %d / %d Zellen (Sand %.0f %%), Lagune %d",
                                 seed, Int(year), m.discharge, m.cell % t.cfg.n, m.cell / t.cfg.n,
                                 s.plainLow, s.plainHigh, s.shelf005, s.shelf015, s.shelf03, s.deep,
                                 s.arms, s.islands, s.islandCells, 100 * s.islandSand, s.lagoonCells))
                    lagoons += s.lagoonCells
                    print("  Längsprofil h−sea (−10…+20 Zellen ab Mündung): "
                          + s.profile.map { String(format: "%+.4f", $0) }.joined(separator: " "))
                    if let out = env["RS_OUT"] {
                        try DeltaMetrics.writeMap(t, m, to: "\(out)/delta-s\(seed)-j\(Int(year))-\(m.cell).ppm")
                    }
                }
                let deltas = mouths.filter {
                    let s = DeltaMetrics.shape(t, $0)
                    return s.arms >= 3 && s.islands >= 1
                }.count
                print(String(format: "PUNKT26 s%d J%d: bestes Delta q=%.0f, %d Distributäre, %d Inseln / %d Zellen, Sand %.0f %%; Deltas mit ≥ 3 Armen: %d von %d; Lagunenzellen %d",
                             seed, Int(year), best.q, best.arms, best.islands, best.cells, 100 * best.sand,
                             deltas, mouths.count, lagoons))
                if env["RS_BUDGET"] == "1" {
                    let bdt = Double(env["RS_BUDGET_DT"] ?? "100")!
                    DeltaMetrics.budget(t, mouths: mouths, steps: max(1, Int(1000 / bdt)), dt: bdt)
                }
            }
        }
    }
}

/// Kennzahlen der Mündungen und Deltas. EINE Definition je Kennzahl für die
/// Messung und den Wächter.
enum DeltaMetrics {

    /// Ab so viel D8-Einzugsgebiet (Zellen) zählt eine Mündung als „groß".
    static let bigMouthCells = 5_000.0
    /// Radius der Delta-Zone um die Mündung (Zellen).
    static let zoneRadius = 25

    struct Mouth {
        /// Letzte Landzelle des D8-Laufs.
        let cell: Int
        let discharge: Double
        /// Abflussrichtung (Einheitsvektor, gemittelt über die letzten Zellen).
        let dir: (x: Double, z: Double)
        /// Zellen des Einzugsgebiets.
        let catchment: [Int]
    }

    /// Produktions-Config, für Messreihen verstellt über `RS_DELTA`
    /// („trap=0.5,dist=3,rad=1,elong=1.5,angle=1.2,gen=2,wmin=1,jit=0,top=0.0015,
    /// min=2000"; `off` = Delta-Pass aus, also der Stand davor).
    static func variantConfig(_ env: [String: String]) -> SimConfig {
        var c = SimConfig.production
        guard let spec = env["RS_DELTA"] else { return c }
        if spec == "off" { c.deltaTrapFraction = 0; return c }
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            switch kv[0] {
            case "trap": c.deltaTrapFraction = v
            case "dist": c.deltaBarDistanceWidths = v
            case "rad": c.deltaBarRadiusWidths = v
            case "elong": c.deltaBarElongation = v
            case "wmin": c.deltaMinHalfWidth = v
            case "jit": c.deltaJitter = v
            case "angle": c.deltaBifurcationAngle = v
            case "gen": c.deltaGenerations = Int(v)
            case "top": c.deltaTopset = v
            case "min": c.deltaMinCells = v
            default: continue
            }
        }
        return c
    }

    static func world(seed: UInt32, year: Double, env: [String: String]) throws -> Terrain {
        let cache = env["RS_CACHE"].map { "\($0)/delta-\(seed)-\(Int(year))-\(env["RS_VARIANT"] ?? "prod").rsw" }
        if let c = cache, FileManager.default.fileExists(atPath: c) { return try WorldSnapshot.read(from: c) }
        let t = Terrain(config: variantConfig(env), seed: seed,
                        settleYears: SimConfig.productionSettleYears)
        let dt = Double(env["RS_DT"] ?? "1000") ?? 1000
        while t.years < year - 1e-6 { t.step(dtYears: min(dt, year - t.years)) }
        if let c = cache { try WorldSnapshot.write(t, to: c) }
        return t
    }

    /// Mündungen ins Meer (Landzelle, deren D8-Empfänger Meer ist) ab
    /// `bigMouthCells`, absteigend nach Abfluss; Mündungen näher als
    /// `zoneRadius` an einer größeren fallen weg.
    static func bigMouths(_ t: Terrain) -> [Mouth] {
        let n = t.cfg.n, sea = t.cfg.sea, cellArea = t.cfg.cellSize * t.cfg.cellSize
        var cands: [(Int, Double)] = []
        for k in 0..<(n * n) where t.hf[k] > sea {
            let r = Int(t.receiver[k])
            guard r >= 0, t.hf[r] <= sea else { continue }
            let q = t.area[k] / cellArea
            if q >= bigMouthCells { cands.append((k, q)) }
        }
        cands.sort { $0.1 > $1.1 }
        var picked: [(Int, Double)] = []
        for c in cands {
            let ci = c.0 % n, cj = c.0 / n
            if picked.contains(where: { abs($0.0 % n - ci) < zoneRadius && abs($0.0 / n - cj) < zoneRadius }) { continue }
            picked.append(c)
        }
        // Einzugsgebiete über die Empfänger-Kette (memoisiert).
        var label = [Int32](repeating: -1, count: n * n)
        for (index, c) in picked.enumerated() { label[c.0] = Int32(index) }
        var catchments = [[Int]](repeating: [], count: picked.count)
        var path: [Int] = []
        for start in 0..<(n * n) where t.hf[start] > sea && label[start] == -1 {
            path.removeAll(keepingCapacity: true)
            var k = start, result: Int32 = -2
            for _ in 0..<(n * n) {
                if label[k] != -1 { result = label[k]; break }
                path.append(k)
                let r = Int(t.receiver[k])
                if r < 0 || t.hf[r] <= sea { break }
                k = r
            }
            for p in path { label[p] = result }
        }
        for k in 0..<(n * n) where label[k] >= 0 { catchments[Int(label[k])].append(k) }
        return picked.enumerated().map { index, c in
            // Richtung: von 6 Zellen stromauf zur Mündung.
            var up = c.0
            for _ in 0..<6 {
                // Zubringer mit dem größten Einzugsgebiet.
                var best = -1, bestA = 0.0
                let i = up % n, j = up / n
                for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                    let ii = i + di, jj = j + dj
                    guard ii >= 0, ii < n, jj >= 0, jj < n else { continue }
                    let nb = jj * n + ii
                    if Int(t.receiver[nb]) == up && t.area[nb] > bestA { bestA = t.area[nb]; best = nb }
                } }
                if best < 0 { break }
                up = best
            }
            let r = Int(t.receiver[c.0])
            var dx = Double(r % n - up % n), dz = Double(r / n - up / n)
            let l = max(1e-9, (dx * dx + dz * dz).squareRoot())
            dx /= l; dz /= l
            return Mouth(cell: c.0, discharge: c.1, dir: (dx, dz), catchment: catchments[index])
        }
    }

    struct Shape {
        /// Landzellen in der Zone knapp über dem Meer.
        var plainLow = 0, plainHigh = 0
        /// Meereszellen in der Zone nach Wassertiefe.
        var shelf005 = 0, shelf015 = 0, shelf03 = 0, deep = 0
        /// Längsprofil h − sea entlang der Abflussrichtung, −10…+20 Zellen.
        var profile: [Double] = []
        /// Distributäre: 1 + größte Zahl von Inseln, die ein Bogen um die
        /// Mündung quert (k Inseln nebeneinander teilen das Wasser in k + 1
        /// Rinnen). Ohne Insel 1 (die Mündung selbst).
        var arms = 1
        /// Sandinseln (≥ `islandMinCells`): Zahl und Fläche in Zellen.
        var islands = 0
        var islandCells = 0
        /// Anteil der Inselzellen, die der Render hell malt (Sand ≥ 0,5), wenn
        /// eine Sand-Maske übergeben wurde.
        var islandSand = 0.0
        /// Eingeschlossene Lagune: Zellen unter dem Meeresspiegel ohne
        /// Verbindung zum Meer (`h ≤ sea < hf`) in der Delta-Zone. Das Raster
        /// malt sie als See, dunkel neben dem Türkis des Meers.
        var lagoonCells = 0
    }

    /// Radius der Delta-Zone um die Mündung (Zellen) — größer als der Baum
    /// des Delta-Passes reicht.
    static let deltaZoneRadius = 45
    /// Kleinste Insel, die zählt (Zellen): darunter Sprenkel, keine Sandinsel.
    static let islandMinCells = 6

    /// Form der Mündung `m`. `sand`: optional je Zelle „hell gemalt"
    /// (Render-Sand ≥ 0,5) für den Sand-Anteil der Inseln.
    static func shape(_ t: Terrain, _ m: Mouth, sand: [Bool]? = nil) -> Shape {
        let n = t.cfg.n, sea = t.cfg.sea
        var s = Shape()
        let mi = m.cell % n, mj = m.cell / n
        let r = zoneRadius
        for dj in -r...r { for di in -r...r where di * di + dj * dj <= r * r {
            let i = mi + di, j = mj + dj
            guard i >= 0, i < n, j >= 0, j < n else { continue }
            let k = j * n + i
            let d = t.h[k] - sea
            if d > 0 {
                if d <= 0.002 { s.plainLow += 1 } else if d <= 0.006 { s.plainHigh += 1 }
            } else if -d < 0.005 { s.shelf005 += 1 }
            else if -d < 0.015 { s.shelf015 += 1 }
            else if -d < 0.03 { s.shelf03 += 1 }
            else { s.deep += 1 }
        } }
        for step in -10...20 {
            let i = Int((Double(mi) + m.dir.x * Double(step)).rounded())
            let j = Int((Double(mj) + m.dir.z * Double(step)).rounded())
            guard i >= 0, i < n, j >= 0, j < n else { continue }
            s.profile.append(t.h[j * n + i] - sea)
        }
        // Inseln: Land in der Delta-Zone ohne Verbindung zu Land außerhalb.
        let R = deltaZoneRadius
        for dj in -R...R { for di in -R...R where di * di + dj * dj <= R * R {
            let i = mi + di, j = mj + dj
            guard i >= 0, i < n, j >= 0, j < n else { continue }
            let k = j * n + i
            if t.h[k] <= sea && t.hf[k] > sea { s.lagoonCells += 1 }
        } }
        var label = [Int: Int]()        // Zelle → Insel-Nummer (−1 = Festland)
        var sizes: [Int] = []
        for dj in -R...R { for di in -R...R where di * di + dj * dj <= R * R {
            let i0 = mi + di, j0 = mj + dj
            guard i0 >= 1, i0 < n - 1, j0 >= 1, j0 < n - 1 else { continue }
            let start = j0 * n + i0
            guard t.h[start] > sea, label[start] == nil else { continue }
            var comp = [start], stack = [start]
            label[start] = -2
            var mainland = false
            while let k = stack.popLast() {
                for nb in [k - 1, k + 1, k - n, k + n] where t.h[nb] > sea {
                    let ni = nb % n - mi, nj = nb / n - mj
                    if ni * ni + nj * nj > R * R || nb % n < 1 || nb % n >= n - 1
                        || nb / n < 1 || nb / n >= n - 1 { mainland = true; continue }
                    if label[nb] == nil { label[nb] = -2; comp.append(nb); stack.append(nb) }
                }
            }
            let id = (!mainland && comp.count >= islandMinCells) ? sizes.count : -1
            if id >= 0 { sizes.append(comp.count) }
            for k in comp { label[k] = id }
        } }
        s.islands = sizes.count
        s.islandCells = sizes.reduce(0, +)
        if let sand, s.islandCells > 0 {
            let bright = label.filter { $0.value >= 0 && sand[$0.key] }.count
            s.islandSand = Double(bright) / Double(s.islandCells)
        }
        // Bögen um die Mündung (seewärts ±100°): gequerte Inseln zählen.
        let base = atan2(m.dir.z, m.dir.x)
        for radius in 3...R {
            var crossed = 0, last = -3
            for a in stride(from: -100.0, through: 100.0, by: 0.5) {
                let ang = base + a * .pi / 180
                let i = Int((Double(mi) + cos(ang) * Double(radius)).rounded())
                let j = Int((Double(mj) + sin(ang) * Double(radius)).rounded())
                guard i >= 0, i < n, j >= 0, j < n else { continue }
                let k = j * n + i
                let id = t.h[k] > sea ? (label[k] ?? -1) : -3
                if id >= 0 && id != last { crossed += 1 }
                last = id
            }
            s.arms = max(s.arms, crossed + 1)
        }
        return s
    }

    /// Mindestabfluss einer MFD-Rinne auf dem Fächer, als Anteil der Mündung
    /// (nur Draufsicht).
    static let armMinShare = 0.05

    /// Höhenänderung je Pass über `steps` Schritte, aufgeteilt nach Zone
    /// (Meer/Land, Lage zu Beginn) und Einzugsgebiet je Mündung, plus inselweit.
    static func budget(_ t: Terrain, mouths: [Mouth], steps: Int, dt: Double) {
        let n = t.cfg.n, sea = t.cfg.sea
        let r = zoneRadius
        struct Acc { var zoneSea = 0.0, zoneLand = 0.0, catchment = 0.0 }
        var zoneSea: [[Int]] = [], zoneLand: [[Int]] = []
        for m in mouths {
            var zs: [Int] = [], zl: [Int] = []
            let mi = m.cell % n, mj = m.cell / n
            for dj in -r...r { for di in -r...r where di * di + dj * dj <= r * r {
                let i = mi + di, j = mj + dj
                guard i >= 0, i < n, j >= 0, j < n else { continue }
                let k = j * n + i
                if t.h[k] <= sea { zs.append(k) } else { zl.append(k) }
            } }
            zoneSea.append(zs); zoneLand.append(zl)
        }
        var acc = [[String: Acc]](repeating: [:], count: mouths.count)
        var global: [String: (land: Double, shallow: Double, deep: Double)] = [:]
        var last = t.h
        let startH = t.h
        SimProfile.reset()
        SimProfile.enabled = true
        SimProfile.onPassEnd = { name in
            let h = t.h
            defer { last = h }
            guard let name else { return }
            for (mi, _) in mouths.enumerated() {
                var a = acc[mi][name] ?? Acc()
                for k in zoneSea[mi] { a.zoneSea += h[k] - last[k] }
                for k in zoneLand[mi] { a.zoneLand += h[k] - last[k] }
                for k in mouths[mi].catchment { a.catchment += h[k] - last[k] }
                acc[mi][name] = a
            }
            var g = global[name] ?? (0, 0, 0)
            h.withUnsafeBufferPointer { hb in
                last.withUnsafeBufferPointer { lb in
                    startH.withUnsafeBufferPointer { sb in
                        for k in 0..<(n * n) {
                            let d = hb[k] - lb[k]
                            if d == 0 { continue }
                            if sb[k] > sea { g.land += d } else if sb[k] > sea - 0.06 { g.shallow += d } else { g.deep += d }
                        }
                    }
                }
            }
            global[name] = g
        }
        for _ in 0..<steps { t.step(dtYears: dt) }
        SimProfile.onPassEnd = nil
        SimProfile.enabled = false
        let years = Double(steps) * dt
        let per = 1000 / years
        let names = global.keys.sorted()
        print(String(format: "BUDGET inselweit, Σ Δh (Zellen·Höhe) je 1000 J.: %@", ""))
        for name in names {
            let g = global[name]!
            if g.land == 0 && g.shallow == 0 && g.deep == 0 { continue }
            print(String(format: "  %-22@ Land %+9.4f  Schelf(<0.06) %+9.4f  tief %+9.4f",
                         name as NSString, g.land * per, g.shallow * per, g.deep * per))
        }
        for (mi, m) in mouths.enumerated() {
            print(String(format: "BUDGET Mündung q=%.0f (Zone Meer %d / Land %d Zellen, EZG %d Zellen), Σ Δh je 1000 J.:",
                         m.discharge, zoneSea[mi].count, zoneLand[mi].count, m.catchment.count))
            for name in acc[mi].keys.sorted() {
                let a = acc[mi][name]!
                if a.zoneSea == 0 && a.zoneLand == 0 && a.catchment == 0 { continue }
                print(String(format: "  %-22@ Zone-Meer %+9.5f  Zone-Land %+9.5f  EZG %+9.5f",
                             name as NSString, a.zoneSea * per, a.zoneLand * per, a.catchment * per))
            }
        }
    }

    /// Draufsicht einer Mündung als PPM (4 Pixel je Zelle): Meer blau nach
    /// Tiefe, Land grün→braun nach Höhe über NN (gestreckt auf 0…0.03),
    /// MFD-Rinnen ≥ `armMinShare` cyan, D8-Lauf ≥ 320 Zellen dunkelblau.
    static func writeMap(_ t: Terrain, _ m: Mouth, to path: String) throws {
        let n = t.cfg.n, sea = t.cfg.sea, cellArea = t.cfg.cellSize * t.cfg.cellSize
        let r = 50, scale = 4
        let mi = m.cell % n, mj = m.cell / n
        let w = (2 * r + 1) * scale
        var px = [UInt8](repeating: 0, count: w * w * 3)
        for dj in -r...r { for di in -r...r {
            let i = mi + di, j = mj + dj
            var c: (Double, Double, Double) = (0, 0, 0)
            if i >= 0, i < n, j >= 0, j < n {
                let k = j * n + i
                let d = t.h[k] - sea
                if d <= 0 {
                    // seicht (bis 0,005) türkis, tiefer dunkelblau
                    let x = min(1, -d / 0.005), y = min(1, max(0, (-d - 0.005) / 0.05))
                    c = (0.45 - 0.25 * x - 0.15 * y, 0.85 - 0.2 * x - 0.4 * y, 0.85 - 0.1 * x - 0.2 * y)
                } else {
                    let x = min(1, d / 0.03)
                    c = (0.55 + 0.3 * x, 0.65 - 0.15 * x, 0.35 - 0.1 * x)
                    if d < 0.003 { c = (0.97, 0.92, 0.65) }
                    if t.areaMFD[k] >= armMinShare * m.discharge * cellArea { c = (0.2, 0.5, 1.0) }
                    if t.area[k] >= 320 * cellArea { c = (0.05, 0.1, 0.6) }
                }
            }
            for y in 0..<scale { for x in 0..<scale {
                let p = (((dj + r) * scale + y) * w + (di + r) * scale + x) * 3
                px[p] = UInt8(max(0, min(255, c.0 * 255)))
                px[p + 1] = UInt8(max(0, min(255, c.1 * 255)))
                px[p + 2] = UInt8(max(0, min(255, c.2 * 255)))
            } }
        } }
        var data = Data("P6 \(w) \(w) 255\n".utf8)
        data.append(contentsOf: px)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
