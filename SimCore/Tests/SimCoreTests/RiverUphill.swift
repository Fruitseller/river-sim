import XCTest
@testable import SimCore
@testable import SimRender

/// „Flüsse fließen bergauf" (Issue #174, Befund des Projekteigners im
/// Zeitraffer um Jahr 230.000): misst die Höhe der Fluss-BÄNDER, wie
/// `RiverRibbonRenderer` sie baut, entlang des Laufs stromab.
///
/// Gemessen wird am fertigen `RibbonMesh` (Fluss-Streifen, `uv2.x ==
/// ribbonKindRiver`): Bandhöhe wie im Renderer (Spiegel über Wasser, sonst
/// das Gelände unter der Mitte), dazu und die tiefste Stelle des
/// Querschnitts (±Halbbreite + 1,5 Zellen). Ein ANSTIEG ist eine Strecke
/// sichtbarer Stützpunkte, deren Bandhöhe über dem laufenden Minimum
/// ALLER Stützpunkte stromauf liegt; seine Höhe ist das größte Übermaß darin, in
/// Bankfull-Tiefen (`meanderBeltDepthPerWidth` · Breite) gemessen.
enum RibbonUphill {
    struct Event {
        var channel: Int
        /// Der Lauf beginnt schon mit Abfluss ab `renderMinCells` (Kopf liegt
        /// an einem größeren Fluss).
        var startsBig = false
        /// Gipfel liegt stromauf des höchsten Knotens des Laufs.
        var beforeCrest = false
        var node: Int
        /// Gitterkoordinaten des Gipfels.
        var gx: Double, gz: Double
        /// Größtes Übermaß der Bandhöhe über dem laufenden Minimum (Sim-Höhe).
        var excess: Double
        /// Dasselbe in Bankfull-Tiefen des Laufs an der Stelle.
        var depths: Double
        /// Länge der Anstiegs-Strecke in Zellen (Bogenlänge).
        var lengthCells: Double
        /// Gelände unter der Mitte über der tiefsten Stelle des Querschnitts.
        var offBedDepths: Double
        /// Übermaß der tiefsten Querschnitts-Stelle über ihrem eigenen
        /// laufenden Minimum stromauf: steigt das BETT selbst an?
        var floorExcessDepths: Double
        /// Mobilität des nächsten Knotens (0 = steile, feste Strecke).
        var mobility: Double
        /// Kosinus zwischen Bandrichtung und D8-Abfluss der größten Zelle
        /// im 5×5 um den Gipfel (−1 = Band läuft gegen das Gefälle).
        var d8Cos: Double
        /// Abstand (Zellen) zur nächsten D8-Zelle mit mindestens halbem
        /// Abfluss des Laufs.
        var d8Distance: Double
    }

    struct Summary {
        var strips = 0
        var visibleSamples = 0
        /// Sichtbare Stützpunkte, unter denen die Entwässerung (größtes D8-
        /// Einzugsgebiet im 5×5) weniger als ein Viertel des Lauf-Abflusses führt.
        var detachedSamples = 0
        /// Bänder, deren ERSTER Knoten schon Abfluss ab `renderMinCells` trägt.
        var stripsStartingBig = 0
        var events: [Event] = []
        func count(over depths: Double) -> Int { events.filter { $0.depths > depths }.count }
        var sumDepths: Double { events.reduce(0) { $0 + $1.depths } }
        var maxDepths: Double { events.map(\.depths).max() ?? 0 }
        /// Absolut, 1 Sim-Höhe ≈ 2400 m (`meanderBeltDepthPerWidth`).
        func count(overMeters m: Double) -> Int { events.filter { $0.excess * 2400 > m }.count }
        var sumMeters: Double { events.reduce(0) { $0 + $1.excess * 2400 } }
        var maxMeters: Double { (events.map(\.excess).max() ?? 0) * 2400 }
    }

    static let visibleAlpha = 0.25
    /// Rauschgrenze: Übermaß unter einer Viertel-Tiefe zählt nicht.
    static let toleranceDepths = 0.25

    static func measure(_ t: Terrain, mesh: RibbonMesh) -> Summary {
        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2
        let cellArea = cs * cs
        let flagged = mesh.bandChannelFlags.indices.filter { mesh.bandChannelFlags[$0] }
        var riverStrip = 0
        var out = Summary()
        let h = t.h
        func hAt(_ x: Double, _ z: Double) -> Double {
            h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, x, z) }
        }
        for (si, start) in mesh.stripStarts.enumerated() {
            let s0 = Int(start)
            let s1 = si + 1 < mesh.stripStarts.count ? Int(mesh.stripStarts[si + 1]) : mesh.vertices.count
            guard s1 - s0 >= 4, Double(mesh.uv2s[s0].x) == WaterRender.ribbonKindRiver else { continue }
            guard riverStrip < flagged.count else { break }
            let ci = flagged[riverStrip]
            riverStrip += 1
            out.strips += 1
            let ch = t.meander.channels[ci]
            if ch.discharge[0] >= t.cfg.renderMinCells { out.stripsStartingBig += 1 }
            let g = MeanderState.beltGeometry(ch, config: t.cfg, heightAt: { hAt($0.x, $0.z) })
            let cnt = (s1 - s0) / 2
            var gx = [Double](repeating: 0, count: cnt), gz = gx, y = gx, alpha = gx, hw = gx
            for a in 0..<cnt {
                let l = mesh.vertices[s0 + 2 * a], r = mesh.vertices[s0 + 2 * a + 1]
                gx[a] = (Double(l.x + r.x) * 0.5 + half) / cs
                gz[a] = (Double(l.z + r.z) * 0.5 + half) / cs
                let ex = Double(r.x - l.x), ez = Double(r.z - l.z)
                hw[a] = 0.5 * (ex * ex + ez * ez).squareRoot() / cs
                // Höhe, auf die der Renderer das Band legt: Spiegel über Wasser,
                // sonst das Gelände unter der Mitte (die Kanten weichen davon um
                // bis zu ±Halbbreite·`ribbonMaxCrossSlope` ab).
                let k = min(max(Int(gz[a].rounded()), 0), n - 1) * n + min(max(Int(gx[a].rounded()), 0), n - 1)
                y[a] = openWaterSurface(k, h: h, wl: t.waterLevel, sea: t.cfg.sea) ?? hAt(gx[a], gz[a])
                alpha[a] = Double(mesh.colors[s0 + 2 * a].w)
            }
            func nearestNode(_ x: Double, _ z: Double) -> Int {
                var best = 0, bd = Double.infinity
                for (i, p) in ch.nodes.enumerated() {
                    let d = (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)
                    if d < bd { bd = d; best = i }
                }
                return best
            }
            func floorAt(_ a: Int) -> Double {
                let a0 = max(0, a - 1), a1 = min(cnt - 1, a + 1)
                var tx = gx[a1] - gx[a0], tz = gz[a1] - gz[a0]
                let tl = max(1e-9, (tx * tx + tz * tz).squareRoot()); tx /= tl; tz /= tl
                let reach = hw[a] + 1.5
                var lo = Double.infinity, s = -reach
                while s <= reach + 1e-9 { lo = min(lo, hAt(gx[a] - tz * s, gz[a] + tx * s)); s += 0.5 }
                return lo
            }
            var runMin = Double.infinity, floorMin = Double.infinity
            var inEvent = false, cur = Event(channel: ci, node: 0, gx: 0, gz: 0, excess: 0, depths: 0,
                                              lengthCells: 0, offBedDepths: 0, floorExcessDepths: 0,
                                              mobility: 0, d8Cos: 0, d8Distance: 0)
            var peakA = 0
            func close() {
                guard inEvent else { return }
                inEvent = false
                let a = peakA
                let ni = nearestNode(gx[a], gz[a])
                let b = MeanderState.beltWidthCells(discharge: ch.discharge[ni], config: t.cfg)
                let depth = max(1e-12, t.cfg.meanderBeltDepthPerWidth * cs * b)
                cur.node = ni
                cur.startsBig = ch.discharge[0] >= t.cfg.renderMinCells
                let crest = ch.nodes.indices.max { hAt(ch.nodes[$0].x, ch.nodes[$0].z) < hAt(ch.nodes[$1].x, ch.nodes[$1].z) } ?? 0
                cur.beforeCrest = ni <= crest
                cur.gx = gx[a]; cur.gz = gz[a]
                cur.depths = cur.excess / depth
                let fl = floorAt(a)
                cur.offBedDepths = (hAt(gx[a], gz[a]) - fl) / depth
                cur.floorExcessDepths = (fl - floorMin) / depth
                cur.mobility = g.mob[ni]
                // D8 an der Stelle.
                let ci0 = min(max(Int(gx[a].rounded()), 0), n - 1), cj0 = min(max(Int(gz[a].rounded()), 0), n - 1)
                var bk = cj0 * n + ci0
                for j in max(0, cj0 - 2)...min(n - 1, cj0 + 2) {
                    for i in max(0, ci0 - 2)...min(n - 1, ci0 + 2) where t.area[j * n + i] > t.area[bk] { bk = j * n + i }
                }
                let rk = Int(t.receiver[bk])
                let a0 = max(0, a - 2), a1 = min(cnt - 1, a + 2)
                var tx = gx[a1] - gx[a0], tz = gz[a1] - gz[a0]
                let tl = max(1e-9, (tx * tx + tz * tz).squareRoot()); tx /= tl; tz /= tl
                if rk >= 0 {
                    var dx = Double(rk % n - bk % n), dz = Double(rk / n - bk / n)
                    let dl = max(1e-9, (dx * dx + dz * dz).squareRoot()); dx /= dl; dz /= dl
                    cur.d8Cos = dx * tx + dz * tz
                } else { cur.d8Cos = 0 }
                var best = Double.infinity
                let need = 0.5 * ch.discharge[ni] * cellArea
                for j in max(0, cj0 - 8)...min(n - 1, cj0 + 8) {
                    for i in max(0, ci0 - 8)...min(n - 1, ci0 + 8) where t.area[j * n + i] >= need {
                        let d = ((Double(i) - gx[a]) * (Double(i) - gx[a]) + (Double(j) - gz[a]) * (Double(j) - gz[a])).squareRoot()
                        best = min(best, d)
                    }
                }
                cur.d8Distance = best
                if cur.depths > toleranceDepths { out.events.append(cur) }
            }
            var arcStart = 0.0, arc = 0.0
            for a in 0..<cnt {
                if a > 0 { arc += ((gx[a] - gx[a - 1]) * (gx[a] - gx[a - 1]) + (gz[a] - gz[a - 1]) * (gz[a] - gz[a - 1])).squareRoot() }
                guard alpha[a] >= visibleAlpha else {
                    close()
                    runMin = min(runMin, y[a])
                    floorMin = min(floorMin, floorAt(a))
                    continue
                }
                out.visibleSamples += 1
                let ex = y[a] - runMin
                let ni = nearestNode(gx[a], gz[a])
                do {
                    let i0 = min(max(Int(gx[a].rounded()), 0), n - 1), j0 = min(max(Int(gz[a].rounded()), 0), n - 1)
                    var amax = 0.0
                    for j in max(0, j0 - 2)...min(n - 1, j0 + 2) {
                        for i in max(0, i0 - 2)...min(n - 1, i0 + 2) { amax = max(amax, t.area[j * n + i]) }
                    }
                    if amax / cellArea < 0.25 * ch.discharge[ni] { out.detachedSamples += 1 }
                }
                let b = MeanderState.beltWidthCells(discharge: ch.discharge[ni], config: t.cfg)
                let tol = toleranceDepths * t.cfg.meanderBeltDepthPerWidth * cs * b
                if ex > tol {
                    if !inEvent {
                        inEvent = true; arcStart = arc
                        cur = Event(channel: ci, node: 0, gx: 0, gz: 0, excess: 0, depths: 0, lengthCells: 0,
                                    offBedDepths: 0, floorExcessDepths: 0, mobility: 0, d8Cos: 0, d8Distance: 0)
                    }
                    if ex > cur.excess { cur.excess = ex; peakA = a }
                    cur.lengthCells = arc - arcStart
                } else {
                    close()
                }
                runMin = min(runMin, y[a])
                floorMin = min(floorMin, floorAt(a))
            }
            close()
        }
        return out
    }

    static func report(_ label: String, _ t: Terrain, _ s: Summary, top: Int = 8) -> String {
        let cs = t.cfg.cellSize, half = t.cfg.world / 2
        let ev = s.events
        func share(_ pred: (Event) -> Bool) -> String {
            let sum = ev.filter(pred).reduce(0) { $0 + $1.depths }
            return String(format: "%.0f%%", 100 * sum / max(1e-9, s.sumDepths))
        }
        var line = String(format: "UPHILL %@ J%.0f | Bänder %d (Start schon groß %d), sichtbare Stützpunkte %d (abgekoppelt %.0f%%) | Anstiege >0,25/1/3/10 Tiefen: %d/%d/%d/%d, Summe %.1f, max %.1f Tiefen",
                          label, t.years, s.strips, s.stripsStartingBig, s.visibleSamples,
                          100 * Double(s.detachedSamples) / Double(max(1, s.visibleSamples)), ev.count, s.count(over: 1), s.count(over: 3),
                          s.count(over: 10), s.sumDepths, s.maxDepths)
        line += String(format: " | absolut >10/30/100 m: %d/%d/%d, Summe %.0f m, max %.0f m",
                        s.count(overMeters: 10), s.count(overMeters: 30), s.count(overMeters: 100), s.sumMeters, s.maxMeters)
        line += " | Anteil an der Summe: Bett steigt (Sohle ≥ ½ Übermaß) " + share { $0.floorExcessDepths >= 0.5 * $0.depths }
        line += ", Mitte über Sohle >1 Tiefe " + share { $0.offBedDepths > 1 }
        line += ", gegen D8 (cos<0) " + share { $0.d8Cos < 0 }
        line += ", D8-Lauf >3 Zellen weg " + share { $0.d8Distance > 3 }
        line += ", Kopf groß " + share { $0.startsBig }
        line += ", Kopf groß und vor dem Scheitel " + share { $0.startsBig && $0.beforeCrest }
        line += ", feste Strecke (mob 0) " + share { $0.mobility <= 0 }
        for e in ev.sorted(by: { $0.depths > $1.depths }).prefix(top) {
            line += String(format: "\n    Lauf %d Knoten %d @(%.1f,%.1f) Welt (%.1f,%.1f): %.0f m, %.1f Tiefen über %.1f Zellen | Sohle %+.1f, Mitte über Sohle %.1f, mob %.2f, D8 cos %.2f, D8-Lauf %.1f Zellen",
                          e.channel, e.node, e.gx, e.gz, e.gx * cs - half, e.gz * cs - half, e.excess * 2400, e.depths, e.lengthCells,
                          e.floorExcessDepths, e.offBedDepths, e.mobility, e.d8Cos, e.d8Distance)
        }
        return line
    }
}

/// Wächter: ein Fluss-Band steigt stromab nicht sichtbar an
/// (`WaterRender.ribbonUphillFade`). Kunstwelt: eine nach Osten fallende Ebene,
/// darauf eine Zentrumslinie entlang Zeile 24, die über einen 72 m hohen
/// Rücken läuft (so wie eine abgekoppelte Gürtel-Linie im Zeitraffer eine
/// Talwand hinaufläuft). Das D8-Netz darunter ist ein Strahler-3-Baum, damit
/// das Band überhaupt emittiert wird.
final class RibbonUphillTests: XCTestCase {
    private func ridgeWorld(ridge: Double) -> Terrain {
        let config = renderConfig(n: 64)
        let n = config.n, cellArea = config.cellSize * config.cellSize
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                let x = Double(i)
                let bump = x > 24 && x < 34 ? ridge * sin(Double.pi * (x - 24) / 10) : 0
                state.h[k] = 0.3 - 0.0005 * x + bump
                state.receiver[k] = -1
                state.area[k] = 0
                state.areaMFD[k] = 0
                state.streamMap[k] = 0
            }
        }
        state.hf = state.h
        state.waterLevel = state.h
        // Strahler-3-Baum: (8,24) und (9,23) → (9,24) [Ordnung 2];
        // (10,22) und (11,22) → (10,23) [2]; beide → (10,24) [3]; die Zeile fließt ostwärts.
        func link(_ a: (Int, Int), _ b: (Int, Int)) {
            state.receiver[a.1 * n + a.0] = Int32(b.1 * n + b.0)
            state.area[a.1 * n + a.0] = 200 * cellArea
            state.area[b.1 * n + b.0] = 200 * cellArea
        }
        link((9, 23), (9, 24)); link((10, 22), (10, 23)); link((11, 22), (10, 23)); link((10, 23), (10, 24))
        for i in 8..<(n - 2) { link((i, 24), (i + 1, 24)) }
        terrain.restore(state)
        terrain.meander.channels = [
            RiverChannel(nodes: (8..<60).map { MeanderNode(x: Double($0), z: 24) },
                         discharge: Array(repeating: 20 * config.renderMinCells, count: 52))
        ]
        return terrain
    }

    /// (Gitter-x der Mitte, Geländehöhe unter der Mitte, Deckkraft) je Kantenpaar des Fluss-Bands.
    private func riverPairs(_ t: Terrain) -> [(x: Double, ground: Double, alpha: Double)] {
        let mesh = RiverRibbonRenderer().build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        XCTAssertEqual(mesh.bandChannelFlags, [true], "Gegenprobe: die Linie muss ein Band bekommen")
        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2
        let end = mesh.stripStarts.count > 1 ? Int(mesh.stripStarts[1]) : mesh.vertices.count
        return stride(from: 0, to: end, by: 2).map { v in
            let l = mesh.vertices[v], r = mesh.vertices[v + 1]
            let gx = (Double(l.x + r.x) * 0.5 + half) / cs, gz = (Double(l.z + r.z) * 0.5 + half) / cs
            return (gx, bilinearGrid(t.h, gx, gz, n: n), Double(mesh.colors[v].w))
        }
    }

    func testRiverBandDoesNotClimbAboveItsUpstreamWater() {
        let pairs = riverPairs(ridgeWorld(ridge: 0.03))
        var lowest = Double.infinity, climbing = 0, worst = 0.0
        for p in pairs {
            let rise = p.ground - lowest
            if rise > WaterRender.ribbonUphillFadeEnd + 1e-4 && p.alpha > 0.01 {
                climbing += 1
                worst = max(worst, rise)
            }
            lowest = min(lowest, p.ground)
        }
        XCTAssertEqual(climbing, 0, String(format: "Band läuft sichtbar bergauf: %d Kantenpaare, bis %.4f über dem Spiegel stromauf",
                                           climbing, worst))
        // Hinter dem Rücken liegt das Gelände wieder unter dem Lauf davor: dort
        // ist es wieder Wasser, das Band darf nicht ganz verschwinden.
        XCTAssertTrue(pairs.contains { $0.x > 36 && $0.x < 44 && $0.alpha > 0.5 },
                      "hinter dem Rücken muss das Band wieder sichtbar sein")
    }

    /// Wo das Gelände stromab fällt, wirkt die Blende nicht: vor dem Rücken ist
    /// das Band bit-gleich zur Welt ohne Rücken.
    func testUphillFadeLeavesTheDescendingBandBitIdentical() {
        let flat = riverPairs(ridgeWorld(ridge: 0))
        let ridged = riverPairs(ridgeWorld(ridge: 0.03))
        XCTAssertEqual(flat.count, ridged.count)
        XCTAssertTrue(flat.allSatisfy { $0.alpha > 0 || $0.x < 12 || $0.x > 55 }, "ohne Rücken blendet nichts aus")
        for (a, b) in zip(flat, ridged) where a.x < 22 {
            XCTAssertEqual(a.alpha, b.alpha, "x \(a.x)")
        }
    }
}

final class RiverUphillDiagnostics: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Produktionswelt mit Einlauf in 1000-Jahr-Schritten (wie die
    /// Zielbild-Diagnostics), gemessen an den Jahren aus `RS_YEARS`
    /// (Standard „20000,230000"); `RS_SEEDS` Standard „1337,42".
    func testRibbonUphillDiagnostic() throws {
        try skipUnlessMeasuring()
        let seeds = (env["RS_SEEDS"] ?? "1337,42").split(separator: ",").compactMap { UInt32($0) }
        let years = (env["RS_YEARS"] ?? "20000,230000").split(separator: ",").compactMap { Double($0) }.sorted()
        for seed in seeds {
            let t = Terrain(config: MeanderBeltCalibration.variantConfig(), seed: seed, settleYears: SimConfig.productionSettleYears)
            for y in years {
                while t.years < y - 1e-6 { t.step(dtYears: min(1000, y - t.years)) }
                // Roh (ohne das Sicherheitsnetz `fadeUphill`) und gemalt.
                let raw = RiverRibbonRenderer()
                raw.fadesUphill = false
                let rawSummary = RibbonUphill.measure(t, mesh: raw.build(t, hscale: RenderContract.heightScale,
                                                                          lift: RenderContract.riverLift))
                print(RibbonUphill.report("s\(seed) roh", t, rawSummary))
                let faded = RibbonUphill.measure(t, mesh: RiverRibbonRenderer().build(
                    t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift))
                print(String(format: "FADE s%d J%.0f: sichtbare Stützpunkte roh %d, gemalt %d (ausgeblendet %.1f%%), Anstiege >30 m gemalt %d, max %.0f m",
                             seed, t.years, rawSummary.visibleSamples, faded.visibleSamples,
                             100 * (1 - Double(faded.visibleSamples) / Double(max(1, rawSummary.visibleSamples))),
                             faded.count(overMeters: 30), faded.maxMeters))
            }
        }
    }

    /// Verfolgt Läufe über die Zeit an ihrem festen Quellknoten (`RS_HEADS` =
    /// „x,z;x,z" in Zellen, Seed `RS_SEED`): Länge, Höhe von Kopf und Ende,
    /// Abfluss am Kopf und Anteil abgekoppelter Knoten, alle `RS_EVERY` Jahre.
    func testRibbonUphillHistoryDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = UInt32(env["RS_SEED"] ?? "1337")!
        let heads = (env["RS_HEADS"] ?? "138,336;112,289").split(separator: ";").map {
            $0.split(separator: ",").compactMap { Double($0) }
        }
        let every = Double(env["RS_EVERY"] ?? "10000")!
        let end = Double(env["RS_YEAR"] ?? "230000")!
        let t = Terrain(config: MeanderBeltCalibration.variantConfig(), seed: seed, settleYears: SimConfig.productionSettleYears)
        let n = t.cfg.n, cellArea = t.cfg.cellSize * t.cfg.cellSize
        func hAt(_ p: MeanderNode) -> Double { t.h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, p.x, p.z) } }
        func localArea(_ p: MeanderNode) -> Double {
            let i0 = min(max(Int(p.x.rounded()), 0), n - 1), j0 = min(max(Int(p.z.rounded()), 0), n - 1)
            var m = 0.0
            for j in max(0, j0 - 2)...min(n - 1, j0 + 2) { for i in max(0, i0 - 2)...min(n - 1, i0 + 2) { m = max(m, t.area[j * n + i]) } }
            return m / cellArea
        }
        while true {
            for hd in heads {
                guard let ci = t.meander.channels.firstIndex(where: {
                    abs($0.nodes[0].x - hd[0]) < 0.01 && abs($0.nodes[0].z - hd[1]) < 0.01 }) else {
                    print(String(format: "HIST J%.0f Kopf (%.0f,%.0f): kein Lauf", t.years, hd[0], hd[1])); continue
                }
                let ch = t.meander.channels[ci]
                let detached = ch.nodes.indices.filter { localArea(ch.nodes[$0]) < 0.25 * ch.discharge[$0] }.count
                var rises = 0.0
                for i in 1..<ch.nodes.count { rises += max(0, hAt(ch.nodes[i]) - hAt(ch.nodes[i - 1])) }
                print(String(format: "HIST J%.0f Kopf (%.0f,%.0f) Lauf %d: %d Knoten, h Kopf %.4f Ende %.4f (Ende bei %.0f,%.0f), Σ Anstiege %.4f, D8 am Kopf %.0f, Q Kopf %.0f Ende %.0f, abgekoppelt %d%%",
                             t.years, hd[0], hd[1], ci, ch.nodes.count, hAt(ch.nodes[0]), hAt(ch.nodes.last!),
                             ch.nodes.last!.x, ch.nodes.last!.z, rises, localArea(ch.nodes[0]), ch.discharge[0],
                             ch.discharge.last!, 100 * detached / ch.nodes.count))
            }
            if t.years >= end - 1e-6 { break }
            let target = min(end, t.years + every)
            while t.years < target - 1e-6 { t.step(dtYears: min(1000, target - t.years)) }
        }
    }

    /// Abstand der Knoten wandernder Läufe zum nächsten D8-Gerinne mit
    /// mindestens halbem Abfluss des Knotens (Zellen, Suche bis 30): wie weit
    /// liegt ein gesunder Mäander von seiner Rinne? `RS_YEAR`, `RS_SEED`,
    /// `RS_VARIANT`.
    func testBeltCouplingDistanceDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = UInt32(env["RS_SEED"] ?? "1337")!
        let year = Double(env["RS_YEAR"] ?? "20000")!
        let t = try world(seed: seed, year: year)
        let n = t.cfg.n, cellArea = t.cfg.cellSize * t.cfg.cellSize
        let edges = [1.5, 3, 6, 10, 15, 20, 30]
        var bins = [Int](repeating: 0, count: edges.count + 1)
        var total = 0
        for ch in t.meander.channels where MeanderState.migrates(ch, t.cfg) {
            for (i, p) in ch.nodes.enumerated() where i > 0 && i < ch.nodes.count - 1
                && ch.discharge[i] >= t.cfg.meanderBeltMinCells {
                let need = 0.5 * ch.discharge[i] * cellArea
                let i0 = Int(p.x.rounded()), j0 = Int(p.z.rounded())
                var best = Double.infinity
                for j in max(0, j0 - 30)...min(n - 1, j0 + 30) {
                    for ii in max(0, i0 - 30)...min(n - 1, i0 + 30) where t.area[j * n + ii] >= need {
                        let d = ((Double(ii) - p.x) * (Double(ii) - p.x) + (Double(j) - p.z) * (Double(j) - p.z)).squareRoot()
                        best = min(best, d)
                    }
                }
                total += 1
                bins[edges.firstIndex { best <= $0 } ?? edges.count] += 1
            }
        }
        var line = String(format: "KOPPLUNG s%d J%.0f dt %@ %@: %d Knoten mit Abfluss ≥ meanderBeltMinCells, Abstand zur D8-Rinne",
                          seed, t.years, env["RS_DT"] ?? "1000", env["RS_VARIANT"] ?? "Produktion", total)
        var cum = 0
        for (b, e) in edges.enumerated() {
            cum += bins[b]
            line += String(format: " ≤%.1f: %.0f%%", e, 100 * Double(cum) / Double(max(1, total)))
        }
        print(line)
    }

    /// Welt aus dem Cache unter `RS_CACHE` (falls gesetzt), sonst frisch.
    private func world(seed: UInt32, year: Double) throws -> Terrain {
        let cache = env["RS_CACHE"].map { "\($0)/world-\(seed)-\(Int(year))-\(env["RS_VARIANT"] ?? "prod").rsw" }
        if let c = cache, FileManager.default.fileExists(atPath: c) { return try WorldSnapshot.read(from: c) }
        let t = Terrain(config: MeanderBeltCalibration.variantConfig(), seed: seed, settleYears: SimConfig.productionSettleYears)
        // RS_DT: Schrittweite des Laufs (Standard 1000). Die Kopplung (#187)
        // prüft am Schrittanfang; nach einem großen Schritt misst der Abstand
        // auch die Wanderung im Schritt gegen das Abflussfeld vom Anfang.
        let dt = env["RS_DT"].flatMap(Double.init) ?? 1000
        while t.years < year - 1e-6 { t.step(dtYears: min(dt, year - t.years)) }
        if let c = cache { try WorldSnapshot.write(t, to: c) }
        return t
    }

    /// Ausschnitt als PPM (`RS_OUT`), `RS_CROP` = „x0,z0,Größe" in Zellen:
    /// Schummerung, D8-Läufe ab `renderMinCells` blau, Mäander-Linien gelb,
    /// sichtbare Band-Stützpunkte grün (fallend) bzw. rot (über dem laufenden
    /// Minimum). `RS_CHANNEL` druckt das Längsprofil eines Laufs.
    func testRibbonUphillMapDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = UInt32(env["RS_SEED"] ?? "1337")!
        let year = Double(env["RS_YEAR"] ?? "230000")!
        let t = try world(seed: seed, year: year)
        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2, cellArea = cs * cs
        let mesh = RiverRibbonRenderer().build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        print(RibbonUphill.report("s\(seed)", t, RibbonUphill.measure(t, mesh: mesh), top: 20))
        if env["RS_LOCALQ"] == "1" {
            // Gegenprobe: Abfluss je Knoten wie vor Paket B (bilinear, ohne
            // 3×3-Maximum und laufendes Maximum) — nur für den Render, die
            // Welt wird danach nicht weitergerechnet.
            let saved = t.meander.channels
            let area = t.area
            for ci in t.meander.channels.indices {
                t.meander.channels[ci].refreshDischarge { gx, gz in
                    max(0, area.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, gx, gz) } / cellArea)
                }
            }
            let m2 = RiverRibbonRenderer().build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
            print(RibbonUphill.report("s\(seed) lokalQ", t, RibbonUphill.measure(t, mesh: m2), top: 5))
            t.meander.channels = saved
        }
        let crop = (env["RS_CROP"] ?? "0,0,\(n)").split(separator: ",").compactMap { Int($0) }
        let x0 = crop[0], z0 = crop[1], size = crop[2]
        let scale = max(1, 720 / size)
        let w = size * scale
        var px = [UInt8](repeating: 0, count: w * w * 3)
        func put(_ gx: Double, _ gz: Double, _ c: (UInt8, UInt8, UInt8), r: Int = 0) {
            let cx = Int(((gx - Double(x0)) * Double(scale)).rounded()), cz = Int(((gz - Double(z0)) * Double(scale)).rounded())
            for dz in -r...r { for dx in -r...r {
                let x = cx + dx, z = cz + dz
                guard x >= 0, z >= 0, x < w, z < w else { continue }
                let o = (z * w + x) * 3; px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
            }}
        }
        let h = t.h
        for z in 0..<w { for x in 0..<w {
            let i = min(n - 2, max(1, x0 + x / scale)), j = min(n - 2, max(1, z0 + z / scale))
            let k = j * n + i
            let gxs = (h[k + 1] - h[k - 1]), gzs = (h[k + n] - h[k - n])
            let shade = max(0, min(1, 0.6 - (gxs + gzs) * 60))
            let land = (90 + 120 * shade, 90 + 110 * shade, 80 + 90 * shade)
            var c = h[k] <= t.cfg.sea ? (30.0, 40.0, 90.0) : land
            if t.waterLevel[k] - h[k] > 0.0005 && h[k] > t.cfg.sea { c = (150, 215, 235) }
            let a = t.area[k] / cellArea
            if a >= t.cfg.renderMinCells {
                let f = min(1, log10(a / t.cfg.renderMinCells) / 2.5)
                c = (10, 20 + 40 * (1 - f), 120 + 100 * f)
            }
            let o = (z * w + x) * 3; px[o] = UInt8(c.0); px[o + 1] = UInt8(c.1); px[o + 2] = UInt8(c.2)
        }}
        for ch in t.meander.channels { for p in ch.nodes { put(p.x, p.z, (230, 210, 40)) } }
        let ends = t.meander.channels.compactMap { ch in ch.nodes.first.map { ($0, ch.nodes.last!) } }
        // Band-Stützpunkte, gefärbt nach dem Übermaß über dem laufenden Minimum.
        for (si, start) in mesh.stripStarts.enumerated() {
            let s0 = Int(start)
            let s1 = si + 1 < mesh.stripStarts.count ? Int(mesh.stripStarts[si + 1]) : mesh.vertices.count
            guard s1 - s0 >= 4, Double(mesh.uv2s[s0].x) == WaterRender.ribbonKindRiver else { continue }
            var runMin = Double.infinity
            for a in 0..<((s1 - s0) / 2) {
                let l = mesh.vertices[s0 + 2 * a], r = mesh.vertices[s0 + 2 * a + 1]
                guard Double(mesh.colors[s0 + 2 * a].w) >= RibbonUphill.visibleAlpha else { continue }
                let y = (Double(l.y + r.y) * 0.5 - RenderContract.riverLift) / RenderContract.heightScale
                let gx = (Double(l.x + r.x) * 0.5 + half) / cs, gz = (Double(l.z + r.z) * 0.5 + half) / cs
                let ex = (y - runMin) / 0.0015   // ~ eine Bankfull-Tiefe bei b ≈ 4,5
                let c: (UInt8, UInt8, UInt8) = ex > 0.5 ? (255, UInt8(max(0, 200 - 20 * ex)), 0) : (0, 230, 60)
                put(gx, gz, c, r: scale / 3)
                runMin = min(runMin, y)
            }
        }
        for (a, b) in ends { put(a.x, a.z, (255, 0, 255), r: scale); put(b.x, b.z, (255, 255, 255), r: scale) }
        let out = env["RS_OUT"] ?? "/tmp/rs174-uphill/map.ppm"
        var data = Data("P6\n\(w) \(w)\n255\n".utf8)
        data.append(contentsOf: px)
        try data.write(to: URL(fileURLWithPath: out))
        print("KARTE \(out) (\(w)×\(w), Maßstab \(scale))")
        if let chs = env["RS_CHANNEL"], let ci = Int(chs), ci < t.meander.channels.count {
            let ch = t.meander.channels[ci]
            let hAt: (MeanderNode) -> Double = { p in h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, p.x, p.z) } }
            let g = MeanderState.beltGeometry(ch, config: t.cfg, heightAt: hAt)
            print("PROFIL Lauf \(ci): \(ch.nodes.count) Knoten")
            for (i, p) in ch.nodes.enumerated() where i % 3 == 0 {
                let k = min(n - 1, max(0, Int(p.z.rounded()))) * n + min(n - 1, max(0, Int(p.x.rounded())))
                var amax = 0.0
                let i0 = k % n, j0 = k / n
                for j in max(0, j0 - 2)...min(n - 1, j0 + 2) {
                    for ii in max(0, i0 - 2)...min(n - 1, i0 + 2) { amax = max(amax, t.area[j * n + ii]) }
                }
                print(String(format: "  %4d (%.1f,%.1f) Welt (%.1f,%.1f) h %.5f hf-h %.5f wl-h %.5f  Q %.0f  D8max±2 %.0f  mob %.2f  b %.1f",
                             i, p.x, p.z, p.x * cs - half, p.z * cs - half, hAt(p), t.hf[k] - h[k], t.waterLevel[k] - h[k],
                             ch.discharge[i], amax / cellArea, g.mob[i], g.width[i]))
            }
        }
    }
}
