import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Messreihe zum Küsten-Befund aus Issue #174 (Strand-Ring und Sedimentfahnen):
/// wie verteilt sich Sand an der Küste, wie weit reichen die Fahnen. Tabellen:
/// `docs/river-coast-render-measurements.md` §E ff.
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         -Xswiftc -swift-version -Xswiftc 5 --filter testCoastShapeDiagnostic
///
/// `RS_SEED` beschränkt auf einen Seed, `RS_YEAR` setzt das Alter (Standard
/// 20.000), `RS_CACHE` den Welt-Cache (Standard `/tmp/river-sim-coast-cache`),
/// `RS_MAP` einen Ordner für Küstenkarten (PPM).
final class CoastShapeTests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment

    static func world(seed: UInt32, year: Double, cache: String?) throws -> Terrain {
        let path = cache.map { "\($0)/world-\(seed)-\(Int(year)).rsw" }
        if let p = path, FileManager.default.fileExists(atPath: p) { return try WorldSnapshot.read(from: p) }
        let t = Terrain(config: .production, seed: seed, settleYears: SimConfig.productionSettleYears)
        while t.years < year - 1e-6 { t.step(dtYears: min(1000, year - t.years)) }
        t.computeFlow()
        if let p = path { try WorldSnapshot.write(t, to: p) }
        return t
    }

    /// Druckt und hängt die Zeile an `RS_OUT` an (die Konsole des Testläufers
    /// verschluckt Ausgaben, wenn der Lauf schnell endet).
    private func emit(_ line: String) {
        print(line)
        guard let path = env["RS_OUT"] else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    func testCoastShapeDiagnostic() throws {
        try skipUnlessMeasuring()
        let seeds: [UInt32] = env["RS_SEED"].flatMap { UInt32($0) }.map { [$0] } ?? [1337, 42, 20]
        let year = Double(env["RS_YEAR"] ?? "20000")!
        for seed in seeds {
            let t = try Self.world(seed: seed, year: year, cache: env["RS_CACHE"] ?? "/tmp/river-sim-coast-cache")
            emit("\n=== Seed \(seed), Jahr \(Int(year)) ===")
            report(t, seed: seed)
        }
    }

    // MARK: Küstenkennzahlen

    /// Küstenlinie: Landzellen mit Chebyshev-Abstand 1 zum Meer.
    static func coastline(_ t: Terrain) -> [Int] {
        let n = t.cfg.n, dist = CoastMaterial.seaDistance(t)
        var out: [Int] = []
        for j in 2..<(n - 2) { for i in 2..<(n - 2) where dist[j * n + i] == 1 { out.append(j * n + i) } }
        return out
    }

    /// Höchste Höhe über der Zelle in einem Fenster (Radius `r`).
    static func backshore(_ t: Terrain, _ k: Int, radius r: Int) -> Double {
        let n = t.cfg.n, i0 = k % n, j0 = k / n
        var m = t.h[k]
        for j in max(0, j0 - r)...min(n - 1, j0 + r) {
            for i in max(0, i0 - r)...min(n - 1, i0 + r) { m = max(m, t.h[j * n + i]) }
        }
        return m - t.h[k]
    }

    /// Meeresanteil im Fenster (Radius `r`).
    static func seaFraction(_ t: Terrain, _ k: Int, radius r: Int) -> Double {
        let n = t.cfg.n, i0 = k % n, j0 = k / n
        var sea = 0, all = 0
        for j in max(0, j0 - r)...min(n - 1, j0 + r) {
            for i in max(0, i0 - r)...min(n - 1, i0 + r) {
                all += 1
                if t.h[j * n + i] <= t.cfg.sea { sea += 1 }
            }
        }
        return Double(sea) / Double(max(all, 1))
    }

    private func pct(_ a: [Double], _ qs: [Double] = [0.1, 0.25, 0.5, 0.75, 0.9], digits: Int = 4) -> String {
        let s = a.sorted()
        guard !s.isEmpty else { return "—" }
        return qs.map { String(format: "%.\(digits)f", s[min(s.count - 1, Int(Double(s.count) * $0))]) }
            .joined(separator: " / ")
    }

    /// 8er-Komponenten über `mask` (nur Küstenzellen) — Größen absteigend.
    static func components(_ cells: [Int], n: Int) -> [Int] {
        var inSet = Set(cells), sizes: [Int] = []
        while let s = inSet.first {
            var stack = [s]; inSet.remove(s); var c = 0
            while let k = stack.popLast() {
                c += 1
                let i = k % n, j = k / n
                for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                    let nb = (j + dj) * n + i + di
                    if inSet.remove(nb) != nil { stack.append(nb) }
                } }
            }
            sizes.append(c)
        }
        return sizes.sorted(by: >)
    }

    private func report(_ t: Terrain, seed: UInt32) {
        let n = t.cfg.n, sea = t.cfg.sea
        let dist = CoastMaterial.seaDistance(t)
        let buffers = TerrainColorRenderer.buffers(t)
        let coast = Self.coastline(t)
        let sandAt: (Int) -> Bool = { buffers.colors[$0 * 4 + 3] >= 128 }
        let rockAt: (Int) -> Bool = { buffers.surfaces[$0 * 4 + 1] >= 128 }
        // Altes Modell (vor §E): Sand, sobald die Zelle in Reichweite der Brandung
        // flach und niedrig liegt — nur Höhe und lokale Steigung.
        let legacySand = coast.filter { k in
            let slope = Terrain.macroSlope(t.h, k, n)
            return (1 - smoothstep(WaterRender.beachSlopeLo, WaterRender.beachSlopeHi, slope))
                * (1 - smoothstep(WaterRender.beachHeightLo, WaterRender.beachHeightHi, t.h[k] - sea)) >= 0.5
        }
        emit(String(format: "VOR (altes Modell): Sand ≥ 0,5 auf %.1f %% der Küstenlinie in %d Abschnitt(en)",
                    100 * Double(legacySand.count) / Double(max(coast.count, 1)),
                    Self.components(legacySand, n: n).count))
        let sandCoast = coast.filter(sandAt)
        let comps = Self.components(sandCoast, n: n)
        emit(String(format: "Küstenlinie: %d Zellen, Sand ≥ 0,5: %d (%.1f %%), Fels ≥ 0,5: %d (%.1f %%)",
                     coast.count, sandCoast.count, 100 * Double(sandCoast.count) / Double(max(coast.count, 1)),
                     coast.filter(rockAt).count, 100 * Double(coast.filter(rockAt).count) / Double(max(coast.count, 1))))
        emit("Sand-Abschnitte (8er-Komponenten der Küstenlinie): \(comps.count), größte: \(comps.prefix(6).map(String.init).joined(separator: ", ")), "
              + "größter Anteil an der Sand-Küste: \(String(format: "%.0f", 100 * Double(comps.first ?? 0) / Double(max(sandCoast.count, 1)))) %")
        // Sandbreite je Küstenzelle: größter Abstand einer Sandzelle im 5×5-Fenster.
        var hist = [Int](repeating: 0, count: 8)
        for k in coast {
            let i0 = k % n, j0 = k / n
            var w = 0
            for j in (j0 - 2)...(j0 + 2) { for i in (i0 - 2)...(i0 + 2) where i >= 0 && i < n && j >= 0 && j < n {
                let c = j * n + i
                if sandAt(c) { w = max(w, Int(dist[c])) }
            } }
            hist[min(w, 7)] += 1
        }
        emit("Sandbreite (Zellen) an der Küstenlinie, Histogramm 0…7+: \(hist)")
        let relief = coast.map { Self.backshore(t, $0, radius: 8) }
        let sea10 = coast.map { Self.seaFraction(t, $0, radius: 10) }
        let slopes = coast.map { Terrain.macroSlope(t.h, $0, n) }
        let hAbove = coast.map { t.h[$0] - sea }
        emit("Küstenlinie macroSlope p10/25/50/75/90: \(pct(slopes))")
        emit("Küstenlinie Höhe über NN p10/25/50/75/90: \(pct(hAbove))")
        emit("Rückland-Relief (max h im Radius 8 − h) p10/25/50/75/90: \(pct(relief))")
        emit("Meeresanteil im Radius 10 p10/25/50/75/90: \(pct(sea10, digits: 2))")
        for r in [12, 16, 24] {
            emit("Rückland-Relief Radius \(r) p10/25/50/75/90: \(pct(coast.map { Self.backshore(t, $0, radius: r) }))")
        }
        for r in [16, 24, 40] {
            emit("Meeresanteil Radius \(r) p10/25/50/75/90: \(pct(coast.map { Self.seaFraction(t, $0, radius: r) }, digits: 2))")
        }
        reportPlumes(t)
        sweep(t)
        measureCost(t)
        if let dir = env["RS_MAP"] { writeMap(t, buffers: buffers, dist: dist, to: "\(dir)/coast-\(seed).ppm") }
    }

    // MARK: Kosten

    /// Abstandsfeld wie vor §E (Stufen-Erweiterung, `cap` Zellen).
    private func legacySeaDistance(_ terrain: Terrain, cap capCells: Int) -> [UInt8] {
        let n = terrain.cfg.n
        let cap = UInt8(capCells)
        let sea = terrain.cfg.sea
        var dist = terrain.h.map { $0 <= sea ? 0 : cap }
        var next = dist
        for _ in 0..<Int(cap - 1) {
            dist.withUnsafeBufferPointer { sb in
            next.withUnsafeMutableBufferPointer { db in
                let ps = sb.baseAddress!, pd = db.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        let jMin = max(0, j - 1), jMax = min(n - 1, j + 1)
                        for i in 0..<n {
                            let iMin = max(0, i - 1), iMax = min(n - 1, i + 1)
                            var best = ps[j * n + i]
                            for nj in jMin...jMax {
                                for ni in iMin...iMax where ps[nj * n + ni] + 1 < best { best = ps[nj * n + ni] + 1 }
                            }
                            pd[j * n + i] = best
                        }
                    }
                }
            }}
            swap(&dist, &next)
        }
        return dist
    }

    /// Median über 25 Läufe, abwechselnd (interleaved), ms.
    private func measureCost(_ t: Terrain) {
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
        let passes: [(String, () -> Void)] = [
            ("Abstandsfeld alt (Deckel 4)", { _ = self.legacySeaDistance(t, cap: 4) }),
            ("Abstandsfeld alt (Deckel 6)", { _ = self.legacySeaDistance(t, cap: 6) }),
            ("Abstandsfeld neu (Breitensuche, Deckel 6)", { _ = CoastMaterial.seaDistance(t) }),
            ("Küstenfeld neu (shore, mit Abstand)", { _ = CoastMaterial.shore(t) }),
            ("Mündungen (= alte Fahne)", { _ = SedimentPlume.mouths(t) }),
            ("Fahne neu (Mündungen + Pfad)", { _ = SedimentPlume.field(t) }),
            ("TerrainColorRenderer.buffers (neu)", { _ = TerrainColorRenderer.buffers(t) }),
        ]
        var times = [[Double]](repeating: [], count: passes.count)
        for _ in 0..<2 { for p in passes { p.1() } }   // Aufwärmen
        for _ in 0..<25 {
            for (i, p) in passes.enumerated() {
                let start = now(); p.1(); times[i].append(now() - start)
            }
        }
        for (i, p) in passes.enumerated() {
            emit(String(format: "Kosten %-44@ Median %.2f ms (min %.2f)", p.0 as NSString,
                        times[i].sorted()[times[i].count / 2], times[i].min() ?? 0))
        }
    }

    // MARK: Kalibrier-Sweep

    /// Strandanteil, Abschnitte und Felsanteil der Küstenlinie für Alternativen
    /// von `CoastMaterial.Calibration` (nur die Formel; die Höhen- und
    /// Steigungsfenster je Zelle kommen dazu). Zeilen: Name, Strand ≥ 1 Zelle
    /// (% der Küstenlinie), Abschnitte, Felsküste ≥ 0,5 (%), Breiten-Histogramm 0…5.
    private func sweep(_ t: Terrain) {
        let n = t.cfg.n
        let (_, _, seeds) = CoastMaterial.shoreSeeds(t)
        let supply = CoastMaterial.mouthSupply(t, seeds: seeds)
        let r = WaterRender.beachOpenRadiusCells, rr = WaterRender.beachReliefRadiusCells
        let inner = seeds.enumerated().filter { $0.element % n >= 2 && $0.element % n < n - 2 && $0.element / n >= 2 && $0.element / n < n - 2 }
        let metrics = inner.map { (index: $0.offset, k: $0.element,
                                   relief: Self.backshore(t, $0.element, radius: rr),
                                   rise: Self.backshore(t, $0.element, radius: WaterRender.cliffRiseRadiusCells),
                                   open: Self.seaFraction(t, $0.element, radius: r),
                                   noise: CoastMaterial.alongShoreNoise($0.element % n, $0.element / n)) }
        var variants: [(String, CoastMaterial.Calibration)] = [("kalibriert", .calibrated)]
        var c = CoastMaterial.Calibration.calibrated
        c.openLo = 0.40; c.openHi = 0.50; c.exposedShare = 0.2; c.noiseAmplitude = 0.6
        for (lo, hi) in [(0.3, 0.95), (0.35, 1.0), (0.4, 1.05), (0.3, 0.8)] {
            c.potentialLo = lo; c.potentialHi = hi
            variants.append(("V Potenzial \(lo)…\(hi)", c))
        }
        c.potentialLo = 0.35; c.potentialHi = 1.0
        for (rl, rh) in [(0.022, 0.045), (0.018, 0.038)] {
            c.reliefLo = rl; c.reliefHi = rh
            variants.append(("V + Relief \(rl)…\(rh)", c))
        }
        for (name, cal) in variants {
            var widths: [Int: Int] = [:]
            var sandy: [Int] = [], rock = 0
            for m in metrics {
                let b = CoastMaterial.beach(relief: m.relief, rise: m.rise, openness: m.open, supply: supply[m.index],
                                            noise: m.noise, cal)
                let w = Int(b.width.rounded())
                widths[w, default: 0] += 1
                if b.width >= 1 { sandy.append(m.k) }
                if b.cliff >= 0.5 { rock += 1 }
            }
            let hist = (0...5).map { widths[$0] ?? 0 }
            emit(String(format: "  Sweep %-22@ Strand %.1f %%, Abschnitte %d, Fels %.1f %%, Breiten %@", name as NSString,
                         100 * Double(sandy.count) / Double(max(metrics.count, 1)),
                         Self.components(sandy, n: n).count,
                         100 * Double(rock) / Double(max(metrics.count, 1)), "\(hist)" as NSString))
        }
    }

    // MARK: Sedimentfahnen

    /// Stand VOR dem Befund „Rauchfächer" (§F): Konstanten der Fassung, die der
    /// Shader mit Mip-Kette und Strömungs-Zug zeichnete.
    private enum Legacy {
        static let minDischarge = 2000.0, fullDischarge = 40000.0
        static let fullRelief = 0.5, reliefFloor = 0.3, offshore = 4
        static let lengthCells = 5.0 / 0.156, lod = 3.0, spread = 2.0, gain = 2.5, opacity = 0.6
    }

    /// Sichtbar = Anteil der Trübungsfarbe an der Wasserfarbe ab 10 %.
    private static let visibleMix = 0.1

    /// Alte Fahne, wie der Shader sie zeichnet: sechs Abgriffe stromauf, jeder
    /// über die Mip-Stufe gemittelt (Kastenmittel um den Abgriff).
    private func legacyDensity(_ t: Terrain) -> (density: [Double], sources: [Int]) {
        let n = t.cfg.n, sea = t.cfg.sea, cellArea = t.cfg.cellSize * t.cfg.cellSize
        let h = t.h, rec = t.receiver
        // Quellen: Mündungen mit der alten Schwelle, Fracht über das Relief
        // (gleiche Etikettierung wie `SedimentPlume.mouths`).
        var source = [Double](repeating: 0, count: n * n)
        var sources: [Int] = []
        let relief = Dictionary(uniqueKeysWithValues: SedimentPlumeLegacy.mouths(t).map { ($0.land, $0.relief) })
        for (land, relief) in relief {
            let q = t.area[land] / cellArea
            guard q >= Legacy.minDischarge else { continue }
            let lo = Legacy.minDischarge, hi = Legacy.fullDischarge
            let discharge = min(1, max(0, log(max(q, lo) / lo) / log(hi / lo)))
            let load = Legacy.reliefFloor + (1 - Legacy.reliefFloor) * min(1, max(0, relief / Legacy.fullRelief))
            // Quelle `offshore` Zellen in Fließrichtung ins Meer.
            let r = Int(rec[land])
            let di = r % n - land % n, dj = r / n - land / n
            var cell = r
            for _ in 1..<Legacy.offshore {
                let i = cell % n + di, j = cell / n + dj
                guard i >= 0, i < n, j >= 0, j < n, h[j * n + i] <= sea else { break }
                cell = j * n + i
            }
            source[cell] = max(source[cell], discharge * load)
            sources.append(cell)
        }
        // Summenbild für Kastenmittel.
        var sat = [Double](repeating: 0, count: (n + 1) * (n + 1))
        for j in 0..<n { var row = 0.0; for i in 0..<n {
            row += source[j * n + i]; sat[(j + 1) * (n + 1) + i + 1] = sat[j * (n + 1) + i + 1] + row
        } }
        func boxMean(_ x: Double, _ y: Double, _ size: Double) -> Double {
            let r = size / 2
            let i0 = max(0, Int((x - r).rounded())), i1 = min(n, Int((x + r).rounded()))
            let j0 = max(0, Int((y - r).rounded())), j1 = min(n, Int((y + r).rounded()))
            guard i1 > i0, j1 > j0 else { return 0 }
            let s = sat[j1 * (n + 1) + i1] - sat[j0 * (n + 1) + i1] - sat[j1 * (n + 1) + i0] + sat[j0 * (n + 1) + i0]
            return s / (size * size)
        }
        let dx = WaterRender.oceanWaveDriftX, dz = WaterRender.oceanWaveDriftZ
        let dn = (dx * dx + dz * dz).squareRoot(), cx = dx / dn, cz = dz / dn
        var density = [Double](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n where h[j * n + i] <= sea {
            var sum = 0.0
            for tap in 0..<6 {
                let u = Double(tap) / 5, lod = Legacy.lod + u * Legacy.spread
                sum += boxMean(Double(i) + 0.5 - cx * u * Legacy.lengthCells,
                               Double(j) + 0.5 - cz * u * Legacy.lengthCells, exp2(lod)) * exp2(2 * lod)
            }
            density[j * n + i] = 1 - exp(-sum / 6 * Legacy.gain)
        } }
        return (density, sources)
    }

    /// Fläche, Reichweite und Küstenabstand der sichtbaren Fahnen.
    private func plumeMetrics(_ t: Terrain, density: [Double], opacity: Double, mouths: [Int]) -> String {
        let n = t.cfg.n, sea = t.cfg.sea
        let dist = Self.landDistance(t)
        var area = 0, far = 0.0, offshore = 0.0
        var offshoreSum = 0.0
        for k in 0..<(n * n) where density[k] * opacity >= Self.visibleMix {
            area += 1
            offshoreSum += dist[k]
            offshore = max(offshore, dist[k])
            // Zur nächsten Quelle: so weit liegt die sichtbare Zelle von ihrer Mündung.
            var nearest = Double.infinity
            for m in mouths {
                nearest = min(nearest, Double((k % n - m % n) * (k % n - m % n) + (k / n - m / n) * (k / n - m / n)).squareRoot())
            }
            far = max(far, nearest)
        }
        _ = sea
        return String(format: "%d Fahnen, sichtbare Fläche %d Zellen (%.2f %% der Meeresfläche im Sim-Quadrat), "
                      + "größte Entfernung zur Mündung %.0f Zellen, Abstand zur Küste max %.0f / Ø %.1f Zellen",
                      mouths.count, area, 100 * Double(area) / Double(max(1, (0..<(n * n)).filter { t.h[$0] <= sea }.count)),
                      far, offshore, area > 0 ? offshoreSum / Double(area) : 0)
    }

    /// Euklidischer Abstand jeder Meereszelle zum nächsten Land (Zellen, bis 40).
    static func landDistance(_ t: Terrain) -> [Double] {
        let n = t.cfg.n, sea = t.cfg.sea
        var d = [Double](repeating: 0, count: n * n)
        let r = 40
        // Zweistufig billig: Chebyshev-Abstand per BFS vom Land, genau genug.
        var dist = [Int](repeating: Int.max, count: n * n)
        var queue: [Int] = []
        for k in 0..<(n * n) where t.h[k] > sea { dist[k] = 0; queue.append(k) }
        var head = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            guard dist[k] < r else { continue }
            let i = k % n, j = k / n
            for nj in max(0, j - 1)...min(n - 1, j + 1) { for ni in max(0, i - 1)...min(n - 1, i + 1) {
                let nb = nj * n + ni
                if dist[nb] == Int.max { dist[nb] = dist[k] + 1; queue.append(nb) }
            } }
        }
        for k in 0..<(n * n) { d[k] = dist[k] == Int.max ? Double(r) : Double(dist[k]) }
        return d
    }

    private func reportPlumes(_ t: Terrain) {
        let mouthsAll = SedimentPlumeLegacy.mouths(t)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let qs = mouthsAll.map { t.area[$0.land] / cellArea }.sorted(by: >)
        emit("Mündungen ins Meer ≥ 2000 Zellen: \(qs.filter { $0 >= 2000 }.count); q: \(qs.prefix(14).map { Int($0) })")
        let old = legacyDensity(t)
        emit("Fahne VOR: " + plumeMetrics(t, density: old.density, opacity: Legacy.opacity, mouths: old.sources))
        let mouths = SedimentPlume.mouths(t)
        let field = SedimentPlume.field(t).map(Double.init)
        emit("Fahne NACH: " + plumeMetrics(t, density: field, opacity: WaterRender.oceanPlumeOpacity,
                                           mouths: mouths.map(\.seaCell)))
        emit("  Stärken NACH: \(mouths.map { String(format: "%.2f", SedimentPlume.strength($0)) })")
        emit("  Mündungen (i, j, q): \(mouths.map { "(\($0.landCell % t.cfg.n), \($0.landCell / t.cfg.n), \(Int($0.dischargeCells)))" })")
    }

    /// Küstenkarte: Schummerung, Meer blau, Sand gelb, Küstenfels rot.
    private func writeMap(_ t: Terrain, buffers: TerrainColorRenderer.Buffers, dist: [UInt8], to path: String) {
        let n = t.cfg.n, sea = t.cfg.sea
        let plume = SedimentPlume.field(t)
        var out = Data("P6\n\(n) \(n)\n255\n".utf8)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                var r = 0.0, g = 0.0, b = 0.0
                if t.h[k] <= sea {
                    (r, g, b) = (0.10, 0.25, 0.45)
                    let d = Double(plume[k])
                    if d > 0.02 { (r, g, b) = (0.10 + 0.8 * d, 0.25 + 0.4 * d, 0.45 - 0.3 * d) }
                } else {
                    let dx = i + 1 < n ? t.h[k + 1] - t.h[k] : 0, dz = j + 1 < n ? t.h[k + n] - t.h[k] : 0
                    let shade = max(0.2, min(1, 0.6 - 25 * (dx + dz)))
                    (r, g, b) = (0.35 * shade, 0.5 * shade, 0.3 * shade)
                    if buffers.colors[k * 4 + 3] >= 128 { (r, g, b) = (0.95, 0.85, 0.5) }
                    else if buffers.surfaces[k * 4 + 1] >= 128 && dist[k] <= 3 { (r, g, b) = (0.9, 0.2, 0.2) }
                }
                out.append(contentsOf: [UInt8(255 * r), UInt8(255 * g), UInt8(255 * b)])
            }
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? out.write(to: URL(fileURLWithPath: path))
    }
}

/// Alle D8-Mündungen ins Meer ohne Abflussschwelle (Landzelle + Relief des
/// Einzugsgebiets) — die Etikettierung aus `SedimentPlume.mouths`, für den
/// Vorher-Nachher-Vergleich der Messreihe.
enum SedimentPlumeLegacy {
    static func mouths(_ terrain: Terrain) -> [(land: Int, relief: Double)] {
        let n = terrain.cfg.n, cnt = n * n, sea = terrain.cfg.sea
        let h = terrain.h, rec = terrain.receiver
        var label = [Int32](repeating: -1, count: cnt)
        var mouthCells: [Int] = [], relief: [Double] = [], path: [Int] = []
        for start in 0..<cnt where h[start] > sea && label[start] == -1 {
            path.removeAll(keepingCapacity: true)
            var k = start
            var result: Int32 = -2
            for _ in 0..<cnt {
                if label[k] != -1 { result = label[k]; break }
                path.append(k)
                let r = Int(rec[k])
                if r < 0 || r >= cnt { break }
                if h[r] <= sea { result = Int32(mouthCells.count); mouthCells.append(k); relief.append(0); break }
                k = r
            }
            for p in path {
                label[p] = result
                if result >= 0 { relief[Int(result)] = max(relief[Int(result)], h[p] - sea) }
            }
        }
        return zip(mouthCells, relief).map { (land: $0, relief: $1) }
    }
}
