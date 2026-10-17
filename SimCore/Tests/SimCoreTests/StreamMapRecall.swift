import XCTest
@testable import SimCore
@testable import SimRender

// Messlauf zur Stream-Map der großen Läufe auf der Produktions-Config
// (Issue #174, Befund „Stream-Map trackt die großen Läufe schlechter",
// docs/zielbild-measurements.md). Alles hinter RS_MEASURE.
//
// Die Stream-Map (`Terrain.streamMap`, EWMA der reife-gewichteten
// Tropfen-Besuche) steuert über `WaterRender.trackMask` die Raster-Läufe. Der
// Wächter `testStreamMapMarksAndPersists` pinnt die alte Großform und misst dort
// Recall > 0,4; auf der neuen Form (n = 256) 0,15. Hier: wie groß ist das
// Problem auf dem Produktionsgitter, WO sitzt es (Flachland gegen Gebirge,
// Abfluss-Fenster), und ist es SICHTBAR, also nicht von einem Band, vom
// Abfluss-Vertrauen (`WaterRender.ribbonTrust`) oder einem See gedeckt?
//
// RS_SEEDS (Standard „1337,42,20"), RS_CHECKPOINTS (Jahre nach der Generierung,
// Standard „0,5000,20000").
final class StreamMapRecallDiagnostics: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private var seeds: [UInt32] {
        (env["RS_SEEDS"] ?? "1337,42,20").split(separator: ",").compactMap { UInt32($0) }
    }
    private var checkpoints: [Double] {
        (env["RS_CHECKPOINTS"] ?? "0,5000,20000").split(separator: ",").compactMap { Double($0) }
    }

    /// Zählt Zellen einer Gruppe: wie viele sind getrackt (Stream-Map über der
    /// Schwelle des Wächters), wie viele sichtbar gemalt, und wie viele der
    /// UNgetrackten sind trotzdem gemalt (Band, Vertrauen, See).
    struct Tally {
        var cells = 0, tracked = 0, painted = 0, untracked = 0, untrackedPainted = 0
        var streamSum = 0.0
        mutating func add(stream: Double, painted p: Bool) {
            cells += 1; streamSum += stream
            let tr = stream > 0.2
            if tr { tracked += 1 } else { untracked += 1; if p { untrackedPainted += 1 } }
            if p { painted += 1 }
        }
        func pct(_ a: Int, _ b: Int) -> Double { b == 0 ? .nan : 100 * Double(a) / Double(b) }
        var line: String {
            String(format: "N %6d | Stream>0,2 %5.1f%% (Mittel %.2f) | gemalt %5.1f%% Lücke %5.1f%% | ungetrackt %6d, davon gemalt %5.1f%%",
                   cells, pct(tracked, cells), cells == 0 ? .nan : streamSum / Double(cells),
                   pct(painted, cells), 100 - pct(painted, cells),
                   untracked, pct(untrackedPainted, untracked))
        }
    }

    /// Gemalt = im 3×3 Band-Deckung ab `protectBandThreshold`, Raster-Fluss
    /// oder See über den Schutz-Schwellen (dieselbe Regel wie
    /// `RiverBeltRenderDiagnostics.mainStem`).
    static func painted(_ k: Int, n: Int, coverage: [Double], water: [UInt8], radius: Int = 1) -> Bool {
        let riverT = byte01(WaterRender.protectRiverThreshold)
        let lakeT = byte01(WaterRender.protectLakeThreshold)
        let i = k % n, j = k / n
        for dj in -radius...radius { for di in -radius...radius {
            let ni = i + di, nj = j + dj
            guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
            let nk = nj * n + ni
            if nk < coverage.count, coverage[nk] >= WaterRender.protectBandThreshold { return true }
            if water[nk * 4] >= riverT || water[nk * 4 + 1] >= lakeT { return true }
        }}
        return false
    }

    func testStreamMapRecallDiagnostic() throws {
        try skipUnlessMeasuring()
        for seed in seeds {
            let t = Terrain(config: SimConfig.production, seed: seed,
                            settleYears: SimConfig.productionSettleYears)
            let start = t.years
            for cp in checkpoints {
                while t.years < start + cp - 1e-6 { t.step(dtYears: 100) }
                Self.report(t, seed: seed, label: cp)
            }
        }
    }

    static func report(_ t: Terrain, seed: UInt32, label: Double) {
        let render = RenderState(geometryMode: true)
        render.renderGrid = 0
        guard let o = render.frame(t, .settled, now: 0).overlays else { XCTFail(); return }
        let coverage = render.riverRibbonMesh.bandCoverage
        let n = t.cfg.n, cellArea = t.cfg.cellSize * t.cfg.cellSize
        let creek = t.cfg.renderMinCells, sea = t.cfg.sea
        func window(_ q: Double) -> Int {
            q < WaterRender.ribbonTrustLoReferences * creek ? 0
                : (q < WaterRender.ribbonTrustHiReferences * creek ? 1 : 2)
        }
        let windowNames = ["Q <3×", "Q 3…10×", "Q ≥10×"]
        let edges = [0.002, 0.005, 0.012]
        func bucket(_ s: Double) -> Int { edges.firstIndex { s < $0 } ?? edges.count }
        let bucketNames = edges.enumerated().map { i, e in
            i == 0 ? String(format: "Gefälle <%.3f", e) : String(format: "%.3f…%.3f", edges[i - 1], e)
        } + [String(format: "≥%.3f", edges.last!)]

        print(String(format: "=== STREAMREC s%d J%.0f n=%d creek=%.0f | Land %d",
                     seed, t.years, n, creek, t.h.filter { $0 > sea }.count))

        // 1. MFD-Läufe (die Menge, die das Raster per Track-Maske gated) und
        //    D8-Läufe (was ein Nutzer als „Fluss" erwartet), je nach Gefälle
        //    und Abfluss-Fenster.
        for (title, useD8) in [("MFD", false), ("D8 ", true)] {
            var byBucket = [Tally](repeating: Tally(), count: edges.count + 1)
            var byWindow = [Tally](repeating: Tally(), count: 3)
            var all = Tally()
            var slopes: [Double] = []
            for j in 2..<(n - 2) { for i in 2..<(n - 2) {
                let k = j * n + i
                guard t.h[k] > sea, t.waterLevel[k] > sea else { continue }
                let q = (useD8 ? t.area[k] : t.areaMFD[k]) / cellArea
                guard q >= creek else { continue }
                let slope = Terrain.macroSlope(t.h, k, n)
                slopes.append(slope)
                let p = painted(k, n: n, coverage: coverage, water: o.water)
                byBucket[bucket(slope)].add(stream: t.streamMap[k], painted: p)
                byWindow[window(q)].add(stream: t.streamMap[k], painted: p)
                all.add(stream: t.streamMap[k], painted: p)
            }}
            slopes.sort()
            func qs(_ p: Double) -> Double { slopes.isEmpty ? .nan : slopes[min(slopes.count - 1, Int(p * Double(slopes.count)))] }
            print(String(format: "  %@-Läufe ≥ creek: Gefälle p10 %.4f p25 %.4f p50 %.4f p75 %.4f p90 %.4f", title, qs(0.1), qs(0.25), qs(0.5), qs(0.75), qs(0.9)))
            print("    alle           \(all.line)")
            for (i, nm) in bucketNames.enumerated() { print("    \(nm.padding(toLength: 15, withPad: " ", startingAt: 0))\(byBucket[i].line)") }
            for (i, nm) in windowNames.enumerated() { print("    \(nm.padding(toLength: 15, withPad: " ", startingAt: 0))\(byWindow[i].line)") }
        }

        // 2. Hauptlauf (D8) zur Küste: Anteil mit Stream-Map > 0,2, Lücke nach
        //    Abfluss-Fenster und Lage (Mündungs-/Mittel-/Quelldrittel).
        let path = RiverBeltRenderDiagnostics.stemPath(t)
        var stemWindow = [Tally](repeating: Tally(), count: 3)
        var stemThird = [Tally](repeating: Tally(), count: 3)
        for (idx, k) in path.enumerated() {
            let p = painted(k, n: n, coverage: coverage, water: o.water)
            let q = t.areaMFD[k] / cellArea
            stemWindow[window(q)].add(stream: t.streamMap[k], painted: p)
            stemThird[min(2, 3 * idx / max(1, path.count))].add(stream: t.streamMap[k], painted: p)
        }
        // Warum bleibt eine Hauptlauf-Zelle ungemalt? Die Bedingungen des
        // Rasters (`WaterFieldRenderer.bytes`) der Reihe nach nachgerechnet.
        var causes: [String: Int] = [:]
        var causesStem = 0
        var ratioByBucket = [[Double]](repeating: [], count: edges.count + 1)
        for k in path {
            let i = k % n, j = k / n
            if i >= 2, j >= 2, i < n - 2, j < n - 2, t.area[k] > 0 {
                ratioByBucket[bucket(Terrain.macroSlope(t.h, k, n))].append(t.areaMFD[k] / t.area[k])
            }
            if painted(k, n: n, coverage: coverage, water: o.water) { continue }
            causesStem += 1
            let cu = t.areaMFD[k] / cellArea
            var near = 0.0
            for dj in -1...1 { for di in -1...1 {
                let ni = i + di, nj = j + dj
                guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                near = max(near, coverage[nj * n + ni])
            }}
            let cause: String
            if t.h[k] <= sea || t.waterLevel[k] <= sea { cause = "Meer" }
            else if t.waterLevel[k] - t.h[k] > WaterRender.streamPondTolerance { cause = "Pond>0,01" }
            else if cu < creek { cause = "MFD<creek" }
            else if WaterRender.ribbonTrust(dischargeCells: cu, referenceCells: creek) == 0
                        && WaterRender.trackMask(streamMap: t.streamMap[k]) == 0 { cause = "ohne Vertrauen+Track" }
            else if near > 0 { cause = "Band daneben" }
            else { cause = "Pipeline" }
            causes[cause, default: 0] += 1
        }
        func med(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[a.count / 2] }
        print("  Stamm-Lücken \(causesStem): " + causes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " | ")
              + String(format: " || areaMFD/area Median je Gefälle: %@",
                       ratioByBucket.map { String(format: "%.2f(%d)", med($0), $0.count) }.joined(separator: " ")))
        let s = RiverBeltRenderDiagnostics.mainStem(t, render: render, water: o.water)
        print(String(format: "  Hauptlauf %d Zellen: Band %.1f%% Raster %.1f%% See %.1f%% Lücke %.1f%% (längste %d)",
                     s.cells, s.band, s.raster, s.lake, s.gap, s.longestGap))
        for (i, nm) in windowNames.enumerated() { print("    Stamm \(nm.padding(toLength: 9, withPad: " ", startingAt: 0))\(stemWindow[i].line)") }
        for (i, nm) in ["Mündung", "Mitte", "Quelle"].enumerated() { print("    Stamm \(nm.padding(toLength: 9, withPad: " ", startingAt: 0))\(stemThird[i].line)") }

        // 3. Gegenprobe: dieselbe Welt mit anderer Stream-Map gerendert. „Orakel"
        //    = 1 auf jeder D8-Zelle ≥ creek (ein perfektes Tracking), „null" =
        //    Stream-Map leer (nur Abfluss-Vertrauen und Band tragen). Wenn
        //    „aktuell" nahe an „Orakel" liegt, kostet die Stream-Map nichts;
        //    liegt es nahe an „null", trägt sie nichts bei.
        let original = t.state
        func variant(_ name: String, _ map: [Double]) {
            var st = original; st.streamMap = map; t.restore(st)
            let r = RenderState(geometryMode: true)
            r.renderGrid = 0
            guard let ov = r.frame(t, .settled, now: 0).overlays else { return }
            let cov = r.riverRibbonMesh.bandCoverage
            let stem = RiverBeltRenderDiagnostics.mainStem(t, render: r, water: ov.water)
            // Sichtbare Lücke statt Zell-Lücke: D8-Pfad und Zentrumslinie liegen
            // im Gürtel mehrere Zellen auseinander, ein Band 3 Zellen neben dem
            // Pfad IST der Fluss. Anteil der Hauptlauf-Zellen ohne gemalte
            // Zelle in 4 / 8 Zellen Umkreis und die längste solche Strecke.
            func wide(_ radius: Int) -> (gap: Double, longest: Int) {
                var miss = 0, run = 0, longest = 0
                for k in path {
                    if painted(k, n: n, coverage: cov, water: ov.water, radius: radius) { run = 0 } else {
                        miss += 1; run += 1; longest = max(longest, run)
                    }
                }
                return (100 * Double(miss) / Double(max(1, path.count)), longest)
            }
            let w4 = wide(4), w8 = wide(8)
            var win = [Tally](repeating: Tally(), count: 3)
            for k in 0..<(n * n) where t.h[k] > sea && t.waterLevel[k] > sea && t.area[k] / cellArea >= creek {
                win[window(t.area[k] / cellArea)].add(stream: map[k], painted: painted(k, n: n, coverage: cov, water: ov.water))
            }
            print(String(format: "  Gegenprobe %@ Hauptlauf Lücke %5.1f%% (längste %2d) | ohne Wasser in 4 Zellen %5.1f%% (%2d), in 8 Zellen %5.1f%% (%2d) | D8 gemalt Q<3× %5.1f%% Q3…10× %5.1f%% Q≥10× %5.1f%%",
                         name.padding(toLength: 8, withPad: " ", startingAt: 0), stem.gap, stem.longestGap,
                         w4.gap, w4.longest, w8.gap, w8.longest,
                         win[0].pct(win[0].painted, win[0].cells), win[1].pct(win[1].painted, win[1].cells),
                         win[2].pct(win[2].painted, win[2].cells)))
        }
        var oracle = original.streamMap
        for k in 0..<(n * n) where t.area[k] / cellArea >= creek { oracle[k] = 1 }
        variant("aktuell", original.streamMap)
        variant("Orakel", oracle)
        variant("null", [Double](repeating: 0, count: n * n))
        t.restore(original)
    }
}
