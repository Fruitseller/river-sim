import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Messreihe zu den „rechteckigen Wasserflecken" im Tiefland (Issue #174,
/// Zielbild): langgestreckte dunkle Kästen mit geraden Kanten, die weder wie
/// See noch wie Altarm oder Flussabschnitt aussehen. Tabellen und Befund:
/// `docs/geometry-water-measurements.md` § H.
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         -Xswiftc -swift-version -Xswiftc 5 --filter testRectWaterDiagnostic
///
/// Die Welten werden frisch mit der Produktions-Config erzeugt und wie die
/// Zeitraffer-Bühne in 1000-Jahr-Schritten gealtert. Keine implizit wiederverwendeten
/// `/tmp`-Snapshots: sie könnten nach einer Physik-Änderung einen alten Stand messen.
final class RectWaterTests: XCTestCase {
    private var lastCover: [Double] = []

    static func world(seed: UInt32, years: Double = 20_000) -> Terrain {
        let t = Terrain(config: .production, seed: seed,
                        settleYears: SimConfig.productionSettleYears)
        while t.years < years - 1e-5 { t.step(dtYears: min(1000, years - t.years)) }
        return t
    }

    func testRectWaterDiagnostic() throws {
        try skipUnlessMeasuring()
        let filterSeed = ProcessInfo.processInfo.environment["RS_SEED"].flatMap { UInt32($0) }
        var seeds: [UInt32] = [1337, 42, 20]
        if let list = ProcessInfo.processInfo.environment["RS_SEEDS"] {
            seeds = list.split(separator: ",").compactMap { UInt32($0) }
        }
        for seed in seeds {
            if let fs = filterSeed, seed != fs { continue }
            let t = Self.world(seed: seed)
            var visible: [[UInt8]] = []
            for legacy in [true, false] {
                print("\n=== Seed \(seed), Jahr \(Int(t.years)), Verbreiterung: \(legacy ? "Diamant (alt)" : "Scheibe (neu)") ===")
                visible.append(report(t, seed: seed, legacy: legacy))
            }
            compare(t, alt: visible[0], neu: visible[1], cover: lastCover)
        }
    }

    /// Kosten der Verbreiterung: `WaterFieldRenderer.bytes` mit alter und neuer
    /// Fassung, abwechselnd (interleaved) über mehrere Runden. Die Zeit der
    /// GANZEN Funktion, weil das die Größe ist, die der Frame bezahlt.
    ///
    ///     RS_MEASURE=1 swift test -c release --package-path SimCore \
    ///         -Xswiftc -swift-version -Xswiftc 5 --filter testRectWaterCostDiagnostic
    func testRectWaterCostDiagnostic() throws {
        try skipUnlessMeasuring()
        let rounds = 40
        for seed: UInt32 in [1337, 42, 20] {
            let t = Self.world(seed: seed)
            let render = RenderState(geometryMode: true)
            render.buildRiverRibbons(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
            let mesh = render.riverRibbonMesh
            let fields = [WaterFieldRenderer(), WaterFieldRenderer()]
            fields[0].legacyWiden = true
            fields[1].legacyWiden = false
            var samples: [[Double]] = [[], []]
            // Aufwärmen
            for f in fields { _ = f.bytes(t, blend: 1, geometryMode: true, bandChannelFlags: mesh.bandChannelFlags, bandCoverage: mesh.bandCoverage) }
            for round in 0..<rounds {
                let order = round % 2 == 0 ? [0, 1] : [1, 0]
                for a in order {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = fields[a].bytes(t, blend: 1, geometryMode: true,
                                        bandChannelFlags: mesh.bandChannelFlags, bandCoverage: mesh.bandCoverage)
                    samples[a].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
            }
            func med(_ a: [Double]) -> Double { let s = a.sorted(); return (s[s.count / 2] + s[(s.count - 1) / 2]) / 2 }
            print("Seed \(seed), n = \(t.cfg.n): bytes() ms/Aufruf, 40 interleaved Paare")
            print("  Diamant (alt): \(samples[0].map { String(format: "%.2f", $0) }.joined(separator: " ")) | Median \(String(format: "%.2f", med(samples[0])))")
            print("  Scheibe (neu): \(samples[1].map { String(format: "%.2f", $0) }.joined(separator: " ")) | Median \(String(format: "%.2f", med(samples[1])))")
        }
    }

    @discardableResult
    private func report(_ t: Terrain, seed: UInt32, legacy: Bool) -> [UInt8] {
        let n = t.cfg.n, cnt = n * n, sea = t.cfg.sea
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let field = WaterFieldRenderer()
        field.legacyWiden = legacy
        let water = field.bytes(t, blend: 1, geometryMode: true,
                                bandChannelFlags: render.riverRibbonMesh.bandChannelFlags,
                                bandCoverage: render.riverRibbonMesh.bandCoverage)
        let cover = render.riverRibbonMesh.bandCoverage
        lastCover = cover
        let h = t.h, hf = t.waterLevel
        let cell = t.cfg.cellSize, half = t.cfg.world / 2

        // Draufsicht-Karte der Wasserklassen (PPM → PNG via ffmpeg).
        var rgb = [UInt8](repeating: 0, count: cnt * 3)
        var classes = [Int](repeating: 0, count: cnt)
        let riverLo = Int(WaterRender.riverMaskLo * 255)
        for k in 0..<cnt {
            var c: (UInt8, UInt8, UInt8)
            if h[k] <= sea { c = (18, 28, 54) } else {
                let v = UInt8(min(255, max(40, 70 + (h[k] - sea) * 120)))
                c = (v, v, v)
            }
            let pond = hf[k] > sea && h[k] > sea ? hf[k] - h[k] : 0
            let gate = Int(water[k * 4 + 1])
            let river = Int(water[k * 4])
            if pond > WaterRender.pondContourLo { c = (180, 130, 60); classes[k] = 1 }          // Tümpel < Gate
            if pond > WaterRender.pondContourLo && gate >= 90 { c = (0, 210, 255); classes[k] = 2 } // See-Kanal sichtbar
            if field.wetMeadow[k] { c = (230, 220, 40); classes[k] = 3 }                          // nasse Wiese
            if river >= riverLo && h[k] > sea { c = (40, 200, 60); classes[k] = 4 }               // Raster-Fluss
            if cover[k] > 0.05 { c = (30, 60, 255); classes[k] = 5 }                              // Band
            rgb[k * 3] = c.0; rgb[k * 3 + 1] = c.1; rgb[k * 3 + 2] = c.2
        }
        let header = "P6\n\(n) \(n)\n255\n".data(using: .ascii)!
        let ppm = header + Data(rgb)
        try? ppm.write(to: URL(fileURLWithPath: "/tmp/rw_map_\(seed)_\(legacy ? "alt" : "neu").ppm"))

        // Sichtbares Rasterwasser nach den Shader-Formeln (ohne Wandschwelle):
        // Fluss-Maske (R) bzw. See-Maske (Kontur x Gate), außerhalb der Bänder.
        func window(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
            let u = min(1, max(0, (x - lo) / max(hi - lo, 1e-9))); return u * u * (3 - 2 * u)
        }
        var cls = [UInt8](repeating: 0, count: cnt)   // 1 Fluss, 2 See
        for k in 0..<cnt where h[k] > sea && cover[k] < 0.3 {
            let rm = window(WaterRender.riverMaskLo, WaterRender.riverMaskHi, Double(water[k * 4]) / 255)
            let pond = hf[k] > sea ? max(0, hf[k] - h[k]) : 0
            let lm = window(WaterRender.pondContourLo, WaterRender.pondContourHi, pond)
                * window(WaterRender.lakeGateLo, WaterRender.lakeGateHi, Double(water[k * 4 + 1]) / 255)
            if max(rm, lm) >= 0.5 { cls[k] = rm >= lm ? 1 : 2 }
        }
        var seen = [Bool](repeating: false, count: cnt)
        struct Comp { var cells: [Int]; var i0: Int; var i1: Int; var j0: Int; var j1: Int }
        var comps: [Comp] = []
        for s in 0..<cnt where cls[s] != 0 && !seen[s] {
            var stack = [s]; seen[s] = true
            var c = Comp(cells: [], i0: n, i1: 0, j0: n, j1: 0)
            while let k = stack.popLast() {
                let i = k % n, j = k / n
                c.cells.append(k)
                c.i0 = min(c.i0, i); c.i1 = max(c.i1, i); c.j0 = min(c.j0, j); c.j1 = max(c.j1, j)
                for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && cls[nb] != 0 && !seen[nb] { seen[nb] = true; stack.append(nb) }
            }
            comps.append(c)
        }
        // Gerade Kantenstücke: Zellkanten zwischen innen/außen, zu Läufen entlang einer
        // Achse gruppiert; als „lang" zählt ein Lauf ab `runMin` Zellen.
        func straightFraction(_ c: Comp, runMin: Int) -> (frac: Double, longest: Int) {
            var inside = Set<Int>(c.cells)
            _ = inside.count
            func isIn(_ i: Int, _ j: Int) -> Bool { i >= 0 && i < n && j >= 0 && j < n && inside.contains(j * n + i) }
            var edges = 0, longEdges = 0, longest = 0
            // horizontale Kanten (oben/unten), Läufe entlang i
            for dj in [-1, 1] {
                for j in c.j0...c.j1 {
                    var run = 0
                    for i in c.i0...(c.i1 + 1) {
                        let edge = i <= c.i1 && isIn(i, j) && !isIn(i, j + dj)
                        if edge { run += 1 } else {
                            if run > 0 { edges += run; if run >= runMin { longEdges += run }; longest = max(longest, run) }
                            run = 0
                        }
                    }
                }
            }
            for di in [-1, 1] {
                for i in c.i0...c.i1 {
                    var run = 0
                    for j in c.j0...(c.j1 + 1) {
                        let edge = j <= c.j1 && isIn(i, j) && !isIn(i + di, j)
                        if edge { run += 1 } else {
                            if run > 0 { edges += run; if run >= runMin { longEdges += run }; longest = max(longest, run) }
                            run = 0
                        }
                    }
                }
            }
            inside.removeAll()
            return (edges == 0 ? 0 : Double(longEdges) / Double(edges), longest)
        }
        // Ursache: warum steht an dieser sichtbaren Raster-Fluss-Zelle Wasser?
        // T = Stream-Map trägt (Track-Maske >= 0.5), V = nur das Abfluss-Vertrauen
        // (Track-Maske < 0.1, Vertrauen > 0.3), W = Rest (Verbreiterung, Kette, Blur).
        let creek = t.cfg.renderMinCells
        var causeT = 0, causeV = 0, causeW = 0
        var mfdOnly = 0
        for k in 0..<cnt where cls[k] == 1 {
            let tm = WaterRender.trackMask(streamMap: t.streamMap[k])
            let q = t.areaMFD[k] / (cell * cell)
            let tr = WaterRender.ribbonTrust(dischargeCells: q, referenceCells: creek)
            if tm >= 0.5 { causeT += 1 } else if tm < 0.1 && tr > 0.3 { causeV += 1 } else { causeW += 1 }
            if t.area[k] / (cell * cell) < creek { mfdOnly += 1 }
        }
        print("Raster-Fluss sichtbar: \(causeT + causeV + causeW) Zellen: Stream-Map \(causeT), nur Vertrauen \(causeV), Rest \(causeW); davon D8-Abfluss < renderMinCells: \(mfdOnly)")
        // Kastenmaß: kleinstes umschließendes Rechteck über alle Drehwinkel (5°-Raster).
        // Füllgrad = Fläche / Rechteckfläche, Streckung = lange / kurze Seite.
        func box(_ c: Comp) -> (fill: Double, elong: Double, len: Double, wid: Double) {
            var best = (area: Double.infinity, len: 0.0, wid: 0.0)
            for a in stride(from: 0.0, to: 90.0, by: 5.0) {
                let cs = cos(a * .pi / 180), sn = sin(a * .pi / 180)
                var u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9
                for k in c.cells {
                    let x = Double(k % n), y = Double(k / n)
                    let u = x * cs + y * sn, v = -x * sn + y * cs
                    u0 = min(u0, u); u1 = max(u1, u); v0 = min(v0, v); v1 = max(v1, v)
                }
                let w = u1 - u0 + 1, hh = v1 - v0 + 1
                if w * hh < best.area { best = (w * hh, max(w, hh), min(w, hh)) }
            }
            return (Double(c.cells.count) / best.area, best.len / max(best.wid, 1), best.len, best.wid)
        }
        // Streifenmaß: für lange, schmale Komponenten die Schlängelung (Standardabweichung
        // der Querlage der Mittellinie) und die Breitenschwankung entlang der Hauptachse.
        func strip(_ c: Comp) -> (len: Double, width: Double, wander: Double, widthCV: Double)? {
            // Hauptachse über die Kovarianz der Zellpositionen.
            let m = Double(c.cells.count)
            var mx = 0.0, my = 0.0
            for k in c.cells { mx += Double(k % n); my += Double(k / n) }
            mx /= m; my /= m
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for k in c.cells {
                let dx = Double(k % n) - mx, dy = Double(k / n) - my
                sxx += dx * dx; sxy += dx * dy; syy += dy * dy
            }
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            let ux = cos(theta), uy = sin(theta)
            var bins: [Int: (sum: Double, n: Int)] = [:]
            var umin = 1e9, umax = -1e9
            for k in c.cells {
                let dx = Double(k % n) - mx, dy = Double(k / n) - my
                let u = dx * ux + dy * uy, v = -dx * uy + dy * ux
                umin = min(umin, u); umax = max(umax, u)
                let b = Int((u).rounded(.down))
                var e = bins[b] ?? (0, 0); e.sum += v; e.n += 1; bins[b] = e
            }
            let len = umax - umin + 1
            guard len >= 15, bins.count >= 10 else { return nil }
            let centers = bins.values.map { $0.sum / Double($0.n) }
            let widths = bins.values.map { Double($0.n) }
            let mc = centers.reduce(0, +) / Double(centers.count)
            let wander = (centers.map { ($0 - mc) * ($0 - mc) }.reduce(0, +) / Double(centers.count)).squareRoot()
            let mw = widths.reduce(0, +) / Double(widths.count)
            let cv = (widths.map { ($0 - mw) * ($0 - mw) }.reduce(0, +) / Double(widths.count)).squareRoot() / max(mw, 1e-9)
            return (len, mw, wander, cv)
        }
        var straightStrips = 0, strips = 0, straightCells = 0
        for c in comps where c.cells.count >= 40 {
            guard let st = strip(c), st.len / max(st.width, 1) >= 3 else { continue }
            strips += 1
            if st.wander < 1.0 && st.widthCV < 0.25 {
                straightStrips += 1; straightCells += c.cells.count
                let nf = c.cells.filter { cls[$0] == 1 }.count
                print(String(format: "  gerader Streifen: (%d,%d) %d Zellen (Fluss %d, See %d), Länge %.0f, Breite %.1f, Schlängelung %.2f, Breiten-CV %.2f",
                             (c.i0 + c.i1) / 2, (c.j0 + c.j1) / 2, c.cells.count, nf, c.cells.count - nf, st.len, st.width, st.wander, st.widthCV))
            }
        }
        print("Streifen (Länge >= 15, Streckung >= 3, >= 40 Zellen): \(strips), davon gerade und gleichbreit (Schlängelung < 1, Breiten-CV < 0,25): \(straightStrips) mit \(straightCells) Zellen")
        let big = comps.filter { $0.cells.count >= 20 }
        print("Sichtbares Raster-Wasser (ohne Band): \(comps.count) Komponenten, davon >= 20 Zellen: \(big.count)")
        let ranked = big.map { c -> (Comp, Double, Double, Int) in
            let bw = c.i1 - c.i0 + 1, bh = c.j1 - c.j0 + 1
            let sf = straightFraction(c, runMin: 6)
            return (c, Double(c.cells.count) / Double(bw * bh), sf.frac, sf.longest)
        }.sorted { $0.2 > $1.2 }
        print("Top 25 nach Anteil gerader Kantenläufe (>= 6 Zellen):")
        print("| Zelle (i,j) | Welt (x,z) | Typ F=Fluss S=See | Zellen | bbox | Füllgrad | gerade Kante | längster Lauf | R mittel | pond max | D8 max (Zellen) |")
        for (c, fill, sfr, longest) in ranked.prefix(25) {
            let ci = (c.i0 + c.i1) / 2, cj = (c.j0 + c.j1) / 2
            let x = Double(ci) * cell - half, z = Double(cj) * cell - half
            var nf = 0, ns = 0, rsum = 0.0, pmax = 0.0, amax = 0.0
            for k in c.cells {
                if cls[k] == 1 { nf += 1 } else { ns += 1 }
                rsum += Double(water[k * 4]) / 255; pmax = max(pmax, hf[k] - h[k])
                amax = max(amax, t.area[k] / (cell * cell))
            }
            print(String(format: "| (%d,%d) | (%.1f, %.1f) | F%d S%d | %d | %dx%d | %.2f | %.2f | %d | %.2f | %.3f | %.0f |",
                         ci, cj, x, z, nf, ns, c.cells.count, c.i1 - c.i0 + 1, c.j1 - c.j0 + 1, fill, sfr, longest,
                         rsum / Double(c.cells.count), pmax, amax))
        }
        var boxLike = 0, boxCells = 0
        print("Kastenmaß (Komponenten >= 30 Zellen): Füllgrad des kleinsten Rechtecks, Streckung")
        for c in big where c.cells.count >= 30 {
            let b = box(c)
            if b.fill >= 0.75 && b.elong >= 2.0 {
                boxLike += 1; boxCells += c.cells.count
                let ci = (c.i0 + c.i1) / 2, cj = (c.j0 + c.j1) / 2
                let nf = c.cells.filter { cls[$0] == 1 }.count
                print(String(format: "  Kasten: (%d,%d) %d Zellen (Fluss %d, See %d), %.0f x %.0f, Füllgrad %.2f, Streckung %.1f",
                             ci, cj, c.cells.count, nf, c.cells.count - nf, b.len, b.wid, b.fill, b.elong))
            }
        }
        print("Kästen (Füllgrad >= 0,75, Streckung >= 2): \(boxLike) Komponenten, \(boxCells) Zellen")
        // Gesamtbild: wie viel Rasterwasser trägt lange gerade Kanten?
        var longTotal = 0, cellsTotal = 0
        for c in big { cellsTotal += c.cells.count }
        let longComps = ranked.filter { $0.2 >= 0.5 }
        for (c, _, _, _) in longComps { longTotal += c.cells.count }
        print("Komponenten >= 20 Zellen mit >= 50 % gerader Kante: \(longComps.count) von \(big.count), \(longTotal) von \(cellsTotal) Zellen")
        return cls
    }

    /// Vergleicht die sichtbare Raster-Fläche beider Arme: was nur der alte Arm malt
    /// (verloren) und was nur der neue (gewonnen), samt der größten Verlust-Flecken.
    private func compare(_ t: Terrain, alt: [UInt8], neu: [UInt8], cover: [Double]) {
        let n = t.cfg.n, cnt = n * n
        var lost = 0, gained = 0, both = 0, gone = 0, goneAtBand = 0
        func nearBand(_ k: Int, _ r: Int) -> Bool {
            let i = k % n, j = k / n
            for dj in max(0, j - r)...min(n - 1, j + r) {
                for di in max(0, i - r)...min(n - 1, i + r) where cover[dj * n + di] > 0.3 { return true }
            }
            return false
        }
        var mark = [Bool](repeating: false, count: cnt)
        // „Wirklich verloren": kein sichtbares Wasser des anderen Arms in 3 Zellen Umkreis
        // (die Verbreiterung verschiebt Ränder um ein, zwei Zellen, das ist kein Verlust).
        func near(_ other: [UInt8], _ k: Int, _ r: Int) -> Bool {
            let i = k % n, j = k / n
            for dj in max(0, j - r)...min(n - 1, j + r) {
                for di in max(0, i - r)...min(n - 1, i + r) where other[dj * n + di] != 0 { return true }
            }
            return false
        }
        for k in 0..<cnt {
            let a = alt[k] != 0, b = neu[k] != 0
            if a && b { both += 1 } else if a {
                lost += 1
                if !near(neu, k, 3) { gone += 1; mark[k] = true; if nearBand(k, 4) { goneAtBand += 1 } }
            } else if b { gained += 1 }
        }
        print("Vergleich sichtbare Fläche: beide \(both), nur alt \(lost) (davon ohne neues Wasser in 3 Zellen: \(gone), davon ≤ 4 Zellen neben einem Band: \(goneAtBand)), nur neu \(gained)")
        var seen = [Bool](repeating: false, count: cnt)
        var found: [(cells: Int, i: Int, j: Int, d8: Double)] = []
        for s in 0..<cnt where mark[s] && !seen[s] {
            var stack = [s]; seen[s] = true
            var c = 0, si = 0, sj = 0, d8 = 0.0
            while let k = stack.popLast() {
                c += 1; si += k % n; sj += k / n; d8 = max(d8, t.area[k] / (t.cfg.cellSize * t.cfg.cellSize))
                let i = k % n, j = k / n
                for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && mark[nb] && !seen[nb] { seen[nb] = true; stack.append(nb) }
            }
            found.append((c, si / c, sj / c, d8))
        }
        found.sort { $0.cells > $1.cells }
        print("Größte Verlust-Flecken (nur alt sichtbar): Zellen @ (i,j), D8-Abfluss max")
        for f in found.prefix(8) { print(String(format: "  %d @ (%d,%d), D8 %.0f", f.cells, f.i, f.j, f.d8)) }
    }

}
