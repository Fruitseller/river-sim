import XCTest
@testable import SimCore
@testable import SimRender

// Messläufe zum Render des Mäandergürtels (Issue #174, Paket C Teil 2), alle
// hinter RS_MEASURE. Befunde: docs/river-belt-render-measurements.md.
//
// - testBarAgeDiagnostic: Verteilung des Bankalters (`Terrain.barAge`) und
//   sein Gradient je Zelle auf der Produktionswelt — daraus Sand-Horizont und
//   Scroll-Bar-Periode von `BarMaterial`.
// - testBarSandExtentDiagnostic: Sandfläche aus `BarMaterial` gegen Bank- und
//   Kanalfläche, nach Bankalter, Abstand zur Zentrumslinie und Höhe über
//   bankfull (Befund #174 „Sandwüste in der Schlinge").
// - testBarMeadowDiagnostic: Talboden-Wiese (A-Kanal von `covers`) auf Bank-
//   Zellen nach Bankalter: wie viel der Aue (alte Bank) trägt sie heute, und
//   was änderte eine zweite Quelle aus `barAge` (Review zu #174 D, § H).
// - testMainStemBandDiagnostic: der Hauptlauf (D8, größtes Einzugsgebiet bis
//   zur Band-Schwelle) Zelle für Zelle: wer malt ihn (Band, Raster-Fluss,
//   See), wo bleibt eine Lücke, und warum.
//
// RS_SEEDS (Standard „1337,42,20" = die Matrix-Seeds), RS_YEARS (Standard
// 20000).
final class RiverBeltRenderDiagnostics: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private var seeds: [UInt32] {
        (env["RS_SEEDS"] ?? "1337,42,20").split(separator: ",").compactMap { UInt32($0) }
    }
    private var years: Double { env["RS_YEARS"].flatMap { Double($0) } ?? 20_000 }

    /// Produktionswelt mit Einlauf, in 100-Jahr-Schritten gealtert (wie
    /// `simperf`, nicht in 1000ern: die Gürtel-Teilschritte hängen daran).
    static func productionWorld(seed: UInt32, years: Double) -> Terrain {
        let t = Terrain(config: SimConfig.production, seed: seed,
                        settleYears: SimConfig.productionSettleYears)
        let start = t.years
        while t.years < start + years - 1e-6 { t.step(dtYears: 100) }
        return t
    }

    /// Talboden-Wiese auf Bank-Zellen nach Bankalter. RS_YEARS_LIST (Standard
    /// „2300,20000"), RS_SEEDS, RS_CACHE wie `testBarSandExtentDiagnostic`.
    func testBarMeadowDiagnostic() throws {
        try skipUnlessMeasuring()
        let marks = (env["RS_YEARS_LIST"] ?? "2300,20000").split(separator: ",").compactMap { Double($0) }
        let cache = env["RS_CACHE"]
        for seed in seeds {
            var t: Terrain?
            var start = 0.0
            for mark in marks {
                let path = cache.map { "\($0)/world-s\(seed)-\(Int(mark)).rsw" }
                if let p = path, FileManager.default.fileExists(atPath: p), let w = try? WorldSnapshot.read(from: p) {
                    t = w; start = w.years - mark
                } else {
                    if t == nil {
                        t = Terrain(config: SimConfig.production, seed: seed,
                                    settleYears: SimConfig.productionSettleYears)
                        start = t!.years
                    }
                    while t!.years < start + mark - 1e-6 { t!.step(dtYears: 100) }
                    if let p = path { _ = try WorldSnapshot.write(t!, to: p) }
                }
                Self.printBarMeadow(t!, seed: seed, label: mark)
            }
        }
    }

    static func printBarMeadow(_ t: Terrain, seed: UInt32, label: Double) {
        let n = t.cfg.n, cnt = n * n
        let covers = TerrainColorRenderer.buffers(t).covers
        let render = RenderState(geometryMode: true)
        let forest = render.forestMaskBytes(t)
        let edges = [WaterRender.barSandYearsLo, WaterRender.barSandYearsHi, .infinity]
        var total = [Int](repeating: 0, count: edges.count), meadow = total
        var land = 0, landMeadow = 0, forestOnBank = 0, bank = 0
        for k in 0..<cnt where t.h[k] > t.cfg.sea {
            land += 1
            if covers[k * 4 + 3] >= 128 { landMeadow += 1 }
            guard t.barAge[k] >= 0 else { continue }
            bank += 1
            if forest[k] >= 128 { forestOnBank += 1 }
            let b = edges.firstIndex { t.barAge[k] < $0 } ?? edges.count - 1
            total[b] += 1
            if covers[k * 4 + 3] >= 128 { meadow[b] += 1 }
        }
        func share(_ a: Int, _ b: Int) -> String { String(format: "%.0f %%", 100 * Double(a) / Double(max(1, b))) }
        // Warum trägt alte Bank KEINE Talboden-Wiese? Weltsteigung gegen Höhenband.
        let slopeScale = 2 * RenderContract.heightScale / (t.cfg.world / Double(n))
        let bands = t.heightBands
        var slopeBins = [0, 0, 0, 0], oldBank = 0, aboveBand = 0
        for j in 2..<(n - 2) { for i in 2..<(n - 2) {
            let k = j * n + i
            guard t.h[k] > t.cfg.sea, t.barAge[k] >= WaterRender.barSandYearsHi else { continue }
            oldBank += 1
            if t.h[k] >= bands.coniferLow { aboveBand += 1 }
            let w = Terrain.macroSlope(t.h, k, n) * slopeScale
            slopeBins[w < MaterialRender.valleySlopeLo ? 0 : w < MaterialRender.valleySlopeHi ? 1 : w < 0.6 ? 2 : 3] += 1
        } }
        print("BARMEADOW-WHY s\(seed) J\(Int(label)) | alte Bank \(oldBank): Weltsteigung <0,1: \(share(slopeBins[0], oldBank)), "
              + "0,1–0,3: \(share(slopeBins[1], oldBank)), 0,3–0,6: \(share(slopeBins[2], oldBank)), ≥ 0,6: \(share(slopeBins[3], oldBank)); "
              + "ab Nadelwald-Band: \(share(aboveBand, oldBank))")
        print(String(format: "BARMEADOW s%d J%.0f | Land %d, Talboden ≥ 0,5 %@ | Bank %d (Wald auf Bank %@)",
                     seed, label, land, share(landMeadow, land), bank, share(forestOnBank, bank))
              + " | Talboden-Anteil je Bankalter <\(Int(edges[0])) J.: \(share(meadow[0], total[0])) (\(total[0])), "
              + "\(Int(edges[0]))–\(Int(edges[1])): \(share(meadow[1], total[1])) (\(total[1])), "
              + "≥ \(Int(edges[1])): \(share(meadow[2], total[2])) (\(total[2]))")
    }

    func testBarAgeDiagnostic() throws {
        try skipUnlessMeasuring()
        for seed in seeds {
            let t = Self.productionWorld(seed: seed, years: years)
            let n = t.cfg.n
            let age = t.barAge
            var ages: [Double] = []
            var grads: [Double] = []
            for j in 1..<(n - 1) {
                for i in 1..<(n - 1) {
                    let k = j * n + i
                    guard age[k] >= 0 else { continue }
                    ages.append(age[k])
                    guard age[k - 1] >= 0, age[k + 1] >= 0, age[k - n] >= 0, age[k + n] >= 0 else { continue }
                    let gx = 0.5 * (age[k + 1] - age[k - 1]), gz = 0.5 * (age[k + n] - age[k - n])
                    grads.append((gx * gx + gz * gz).squareRoot())
                }
            }
            ages.sort(); grads.sort()
            func q(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(p * Double(a.count)))] }
            let land = t.h.filter { $0 > t.cfg.sea }.count
            var line = String(format: "BARAGE s%d J%.0f bank %d (%.1f %% Land) | Alter p10 %.0f p25 %.0f p50 %.0f p75 %.0f p90 %.0f",
                              seed, t.years, ages.count, 100 * Double(ages.count) / Double(max(1, land)),
                              q(ages, 0.1), q(ages, 0.25), q(ages, 0.5), q(ages, 0.75), q(ages, 0.9))
            for limit in [100.0, 300, 1000, 3000, 10000] {
                line += String(format: " <%.0f:%.0f%%", limit, 100 * Double(ages.filter { $0 < limit }.count) / Double(max(1, ages.count)))
            }
            line += String(format: " | |∇Alter| J/Zelle p25 %.0f p50 %.0f p75 %.0f p90 %.0f",
                            q(grads, 0.25), q(grads, 0.5), q(grads, 0.75), q(grads, 0.9))
            print(line)
        }
    }

    func testMainStemBandDiagnostic() throws {
        try skipUnlessMeasuring()
        for seed in seeds {
            let t = Self.productionWorld(seed: seed, years: years)
            let render = RenderState(geometryMode: true)
            render.renderGrid = 0
            guard let o = render.frame(t, .settled, now: 0).overlays else { XCTFail(); continue }
            let s = Self.mainStem(t, render: render, water: o.water)
            print(String(format: "STEM s%d J%.0f Zellen %d | Band %.1f%% Raster %.1f%% See %.1f%% Lücke %.1f%% (längste %d, Läufe ≥3: %d) | Lücke mit Zentrumslinie %d (Band verworfen %d) ohne %d | Halbbreite am Deckel %.0f%%",
                         seed, t.years, s.cells, s.band, s.raster, s.lake, s.gap, s.longestGap,
                         s.gapRuns, s.gapWithLine, s.gapDropped, s.gapWithoutLine, s.atCap))
            let n = t.cfg.n
            // Gegenprobe Doppelwasser: Band-Zellen ohne großen D8-Lauf in
            // 3 Zellen Umkreis (Band neben dem echten Abfluss = Geisterlauf).
            do {
                let cov = render.riverRibbonMesh.bandCoverage
                let cellArea = t.cfg.cellSize * t.cfg.cellSize
                var bandCells = 0, ghost = 0
                for k in 0..<(n * n) where cov[k] >= 0.3 {
                    bandCells += 1
                    let i = k % n, j = k / n
                    var hit = false
                    for dj in -3...3 { for di in -3...3 {
                        let ni = i + di, nj = j + dj
                        guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                        if t.area[nj * n + ni] / cellArea >= t.cfg.renderMinCells { hit = true }
                    }}
                    if !hit { ghost += 1 }
                }
                print(String(format: "  Band-Zellen %d, davon ohne D8-Lauf ≥ renderMinCells in 3 Zellen: %d (%.1f%%)",
                             bandCells, ghost, 100 * Double(ghost) / Double(max(1, bandCells))))
                // Doppelwasser direkt (Review #181): Raster-Fluss sichtbar
                // (Schwelle des Shaders) unter einem kräftigen Band.
                let riverT = byte01(WaterRender.riverMaskLo)
                var strong = 0, doubled = 0
                for k in 0..<(n * n) where cov[k] >= 0.7 {
                    strong += 1
                    if o.water[k * 4] >= riverT { doubled += 1 }
                }
                // … und daneben: Raster-Fluss ohne Band, aber ein kräftiges
                // Band in ±3 Zellen (die D8-Treppe parallel zum Band).
                var beside = 0
                for k in 0..<(n * n) where o.water[k * 4] >= riverT && cov[k] < WaterRender.protectBandThreshold {
                    let i = k % n, j = k / n
                    search: for dj in -3...3 { for di in -3...3 {
                        let ni = i + di, nj = j + dj
                        guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                        if cov[nj * n + ni] >= 0.7 { beside += 1; break search }
                    }}
                }
                print(String(format: "  Band-Zellen mit Deckung ≥ 0,7: %d, davon mit Raster-Fluss darunter: %d (%.1f%%) | Raster-Fluss ohne Band neben einem Band (±3 Zellen): %d",
                             strong, doubled, 100 * Double(doubled) / Double(max(1, strong)), beside))
            }
            let near = s.gapLineDistance.filter { $0 <= 4 }.count
            let far = s.gapLineDistance.filter { $0 > 8 }.count
            let upper = s.gapPosition.filter { $0 > 0.66 }.count
            let lower = s.gapPosition.filter { $0 < 0.33 }.count
            let streamMed = s.gapStream.sorted().dropFirst(s.gapStream.count / 2).first ?? 0
            print(String(format: "  Lücken ohne Linie: Linie ≤4 Zellen %d, > 8 Zellen %d | Mündungsdrittel %d, Quelldrittel %d | Stream-Map Median %.2f",
                         near, far, lower, upper, streamMed))
            // Gates der Läufe, die den Hauptlauf berühren: Stream-Map-Stütze
            // (Kanal-Kohärenz), Strahler-Rang, Abfluss.
            let flags = render.riverRibbonMesh.bandChannelFlags
            let orders = t.strahlerOrders(minCells: t.cfg.meanderMinCells)
            for ci in Set(s.channels).sorted() {
                let ch = t.meander.channels[ci]
                var sum = 0.0, wsum = 0.0, maxOrd: Int32 = 0, streamMax = 0.0
                for (a, p) in ch.nodes.enumerated() {
                    let stream = bilinearGrid(t.streamMap, p.x, p.z, n: n)
                    streamMax = max(streamMax, stream)
                    let w = max(smoothstep(0, t.cfg.renderMinCells, ch.discharge[a]), 0.05)
                    sum += WaterRender.corridorMask(streamMap: stream) * w; wsum += w
                    let x = min(max(Int(p.x.rounded()), 0), n - 1), z = min(max(Int(p.z.rounded()), 0), n - 1)
                    maxOrd = max(maxOrd, orders[z * n + x])
                }
                let support = sum / max(wsum, 1e-9)
                let opacity = smoothstep(0, 1, (support - WaterRender.ribbonSupportLo) / WaterRender.ribbonSupportSpan)
                print(String(format: "  Lauf %d Knoten %d Q %.0f…%.0f Band %@ | Stütze %.2f → Deckkraft %.2f, Stream-Map max %.2f, Strahler max %d",
                             ci, ch.nodes.count, ch.discharge.first ?? 0, ch.discharge.last ?? 0,
                             ci < flags.count && flags[ci] ? "ja" : "nein", support, opacity, streamMax, maxOrd))
            }
        }
    }

    /// Vorzeichen der Bogenstärke gegen das Bett der Sim: auf der Seite, die
    /// `WaterRender.ribbonOutward` als Prallhang meldet, muss das Bett tiefer
    /// liegen. Dazu eine Draufsicht (PPM nach RS_OUT, Standard /tmp) des
    /// Gürtel-Materials um den Hauptlauf: Makrofarbe, Sand, Band.
    func testBeltRenderMapDiagnostic() throws {
        try skipUnlessMeasuring()
        let outDir = env["RS_OUT"] ?? "/tmp"
        for seed in seeds {
            let t = Self.productionWorld(seed: seed, years: years)
            let n = t.cfg.n
            // 1. Querprofil-Vorzeichen über ALLE wandernden Läufe.
            var outDepth = 0.0, inDepth = 0.0, samples = 0
            for ch in t.meander.channels where ch.nodes.count >= 10 {
                let bend = MeanderState.bendStrength(ch, config: t.cfg,
                                                     heightAt: { bilinearGrid(t.h, $0.x, $0.z, n: n) })
                for i in 1..<(ch.nodes.count - 1) where abs(bend[i]) > 0.3 {
                    let a = ch.nodes[i - 1], c = ch.nodes[i + 1], m = ch.nodes[i]
                    var tx = c.x - a.x, tz = c.z - a.z
                    let tl = (tx * tx + tz * tz).squareRoot()
                    guard tl > 1e-9 else { continue }
                    tx /= tl; tz /= tl
                    let w = 0.5 * MeanderState.beltWidthCells(discharge: ch.discharge[i], config: t.cfg)
                    // UV.x = 1 liegt bei Mitte + (−tz, tx)·hw (emitRibbon).
                    let h1 = bilinearGrid(t.h, m.x - tz * 0.5 * w, m.z + tx * 0.5 * w, n: n)
                    let h0 = bilinearGrid(t.h, m.x + tz * 0.5 * w, m.z - tx * 0.5 * w, n: n)
                    let out1 = WaterRender.ribbonOutward(across: 1, bend: bend[i]) > 0
                    outDepth += out1 ? -h1 : -h0
                    inDepth += out1 ? -h0 : -h1
                    samples += 1
                }
            }
            print(String(format: "BEND s%d J%.0f Bogen-Stützpunkte %d | Bett außen − innen (Sim-Höhe, + = außen tiefer): %+.5f",
                         seed, t.years, samples, samples > 0 ? (outDepth - inDepth) / Double(samples) : 0))

            // 2. Draufsicht.
            let render = RenderState(geometryMode: true)
            guard let o = render.frame(t, .settled, now: 0).overlays else { continue }
            let cov = render.riverRibbonMesh.bandCoverage
            let bars = render.barMaterial(t)
            guard let main = ZielbildMetrics.mainChannel(t) else { continue }
            let xs = main.nodes.map(\.x), zs = main.nodes.map(\.z)
            let x0 = max(0, Int(xs.min()!) - 20), x1 = min(n - 1, Int(xs.max()!) + 20)
            let z0 = max(0, Int(zs.min()!) - 20), z1 = min(n - 1, Int(zs.max()!) + 20)
            let scale = 3
            let w = (x1 - x0 + 1) * scale, hgt = (z1 - z0 + 1) * scale
            var ppm = "P6\n\(w) \(hgt)\n255\n".data(using: .ascii)!
            var px = [UInt8](repeating: 0, count: w * hgt * 3)
            for z in z0...z1 { for x in x0...x1 {
                let k = z * n + x
                var r = Double(o.colors[k * 4]) / 255, g = Double(o.colors[k * 4 + 1]) / 255, b = Double(o.colors[k * 4 + 2]) / 255
                let veg = Double(o.surfaces[k * 4]) / 255
                r += (0.12 - r) * veg; g += (0.28 - g) * veg; b += (0.08 - b) * veg
                let sand = Double(o.colors[k * 4 + 3]) / 255
                r += (0.70 - r) * sand; g += (0.65 - g) * sand; b += (0.54 - b) * sand
                let forest = Double(o.forestMask[k]) / 255
                r *= 1 - 0.5 * forest; g *= 1 - 0.4 * forest; b *= 1 - 0.5 * forest
                let water = max(cov[k], Double(o.water[k * 4]) / 255 > WaterRender.riverMaskLo ? 0.8 : 0,
                                Double(o.water[k * 4 + 1]) / 255 > WaterRender.lakeGateLo ? 0.8 : 0)
                r += (0.08 - r) * water; g += (0.25 - g) * water; b += (0.45 - b) * water
                if t.h[k] <= t.cfg.sea { r = 0.05; g = 0.15; b = 0.3 }
                for dz in 0..<scale { for dx in 0..<scale {
                    let o3 = (((z - z0) * scale + dz) * w + (x - x0) * scale + dx) * 3
                    px[o3] = byte01(r); px[o3 + 1] = byte01(g); px[o3 + 2] = byte01(b)
                }}
            }}
            ppm.append(contentsOf: px)
            let path = "\(outDir)/belt-render-s\(seed)-\(Int(t.years)).ppm"
            try ppm.write(to: URL(fileURLWithPath: path))
            // Delta-Arme dieses Builds (am Meer liegen sie unter der opaken
            // Meeresebene, sichtbar sind nur die an Seen).
            let mesh = render.riverRibbonMesh
            var deltaStrips = 0
            for st in mesh.stripStarts where mesh.uv2s[Int(st)].x == Float(WaterRender.ribbonKindDelta) {
                deltaStrips += 1
            }
            print("DELTA s\(seed): Delta-Arm-Bänder \(deltaStrips)")
            // Kosten auf der Produktionswelt: Gürtel-Material allein und der
            // Material-Pass mit/ohne Gürtel, interleaved, Median über 7.
            var tField: [Double] = [], tWith: [Double] = [], tWithout: [Double] = [], tLine: [Double] = []
            for _ in 0..<7 {
                var c = Date()
                let f = BarMaterial.field(t)
                tField.append(Date().timeIntervalSince(c) * 1000)
                c = Date()
                _ = BarMaterial.lineDistance(t, barAge: t.barAge, reachWidths: WaterRender.barSandReachHi)
                tLine.append(Date().timeIntervalSince(c) * 1000)
                c = Date(); _ = TerrainColorRenderer.buffers(t, bars: f)
                tWith.append(Date().timeIntervalSince(c) * 1000)
                c = Date(); _ = TerrainColorRenderer.buffers(t, bars: .empty)
                tWithout.append(Date().timeIntervalSince(c) * 1000)
            }
            func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
            print(String(format: "COST s%d: BarMaterial.field %.2f ms (davon Abstand zur Zentrumslinie %.2f ms) | Materialpass mit Gürtel %.2f ms, ohne %.2f ms (Median aus 7, interleaved)",
                         seed, med(tField), med(tLine), med(tWith), med(tWithout)))
            let sandCells = bars.sand.filter { $0 > 0.25 }.count
            let reedCells = bars.reed.filter { $0 > 0.25 }.count
            print("MAP s\(seed): \(path) | Sand > 0,25: \(sandCells) Zellen, Ried > 0,25: \(reedCells) Zellen, Altarme \(t.meander.oxbows.count)")
        }
    }

    struct StemStats {
        var cells = 0
        var band = 0.0, raster = 0.0, lake = 0.0, gap = 0.0
        var longestGap = 0, gapRuns = 0
        var gapWithLine = 0, gapDropped = 0, gapWithoutLine = 0
        var atCap = 0.0
        /// Läufe, deren Zentrumslinie den Hauptlauf berührt.
        var channels: [Int] = []
        var cellsSeen = 0
        /// Lücken ohne Zentrumslinie: Abstand zur nächsten (Zellen, 99 = > 8),
        /// Lage am Lauf (0 = Mündung, 1 = Quelle), Stream-Map dort.
        var gapLineDistance: [Int] = []
        var gapPosition: [Double] = []
        var gapStream: [Double] = []
    }

    /// Hauptlauf = D8-Pfad vom Land mit dem größten Einzugsgebiet stromauf,
    /// je Zelle zum Zubringer mit dem größten Einzugsgebiet, bis der Abfluss
    /// unter `renderMinCells` fällt (ab dort gibt es kein Band mehr). Gezählt
    /// wird, ob eine Zelle als Wasser sichtbar ist: Band-Deckung ab
    /// `protectBandThreshold`, Raster-Fluss/See ab den Schutz-Schwellen (=
    /// Sichtbarkeit im Shader, s. `testProtectMaskReadsVisibilityFromTheShaderWindows`)
    /// — je 3×3, weil D8-Pfad und Zentrumslinie nicht zellgenau
    /// übereinanderliegen.
    static func mainStem(_ t: Terrain, render: RenderState, water: [UInt8]) -> StemStats {
        let n = t.cfg.n, cs = t.cfg.cellSize, cellArea = cs * cs
        let coverage = render.riverRibbonMesh.bandCoverage
        let flags = render.riverRibbonMesh.bandChannelFlags
        var start = -1, best = 0.0
        for k in 0..<(n * n) where t.h[k] > t.cfg.sea && t.area[k] > best { best = t.area[k]; start = k }
        var path: [Int] = []
        var c = start
        while c >= 0, t.area[c] / cellArea >= t.cfg.renderMinCells, path.count < n * n {
            path.append(c)
            let i = c % n, j = c / n
            var next = -1, nextArea = 0.0
            for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                let ni = i + di, nj = j + dj
                guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                let nk = nj * n + ni
                if t.receiver[nk] == Int32(c), t.area[nk] > nextArea { nextArea = t.area[nk]; next = nk }
            }}
            c = next
        }
        // Zellen unter Zentrumslinien: welcher Lauf, ist sein Band gebaut?
        var line = [Int](repeating: -1, count: n * n)
        for (ci, ch) in t.meander.channels.enumerated() {
            for p in ch.nodes {
                let x = min(max(Int(p.x.rounded()), 0), n - 1), z = min(max(Int(p.z.rounded()), 0), n - 1)
                line[z * n + x] = ci
            }
        }
        let riverT = byte01(WaterRender.protectRiverThreshold)
        let lakeT = byte01(WaterRender.protectLakeThreshold)
        var r = StemStats()
        r.cells = path.count
        var run = 0, band = 0, raster = 0, lake = 0, gap = 0, cap = 0
        for k in path {
            r.cellsSeen += 1
            let i = k % n, j = k / n
            var isBand = false, isRiver = false, isLake = false, lineCh = -1
            for dj in -1...1 { for di in -1...1 {
                let ni = i + di, nj = j + dj
                guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                let nk = nj * n + ni
                if nk < coverage.count, coverage[nk] >= WaterRender.protectBandThreshold { isBand = true }
                if water[nk * 4] >= riverT { isRiver = true }
                if water[nk * 4 + 1] >= lakeT { isLake = true }
                if line[nk] >= 0 { lineCh = line[nk]; r.channels.append(line[nk]) }
            }}
            if WaterRender.ribbonHalfWidthCells(dischargeCells: t.area[k] / cellArea,
                                                referenceCells: t.cfg.renderMinCells)
                >= WaterRender.ribbonHalfWidthCapCells { cap += 1 }
            if isBand { band += 1 } else if isRiver { raster += 1 } else if isLake { lake += 1 } else {
                gap += 1; run += 1
                if lineCh >= 0 {
                    r.gapWithLine += 1
                    if lineCh < flags.count, !flags[lineCh] { r.gapDropped += 1 }
                } else {
                    r.gapWithoutLine += 1
                    // Wie weit liegt die nächste Zentrumslinie, und wo am Lauf?
                    var d = 99
                    search: for rad in 2...8 {
                        for dj in -rad...rad { for di in -rad...rad {
                            let ni = i + di, nj = j + dj
                            guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                            if line[nj * n + ni] >= 0 { d = rad; break search }
                        }}
                    }
                    r.gapLineDistance.append(d)
                    r.gapPosition.append(Double(r.cellsSeen) / Double(max(1, path.count)))
                    r.gapStream.append(t.streamMap[k])
                }
                continue
            }
            if run >= 3 { r.gapRuns += 1 }
            r.longestGap = max(r.longestGap, run); run = 0
        }
        if run >= 3 { r.gapRuns += 1 }
        r.longestGap = max(r.longestGap, run)
        let total = Double(max(1, path.count))
        r.band = 100 * Double(band) / total; r.raster = 100 * Double(raster) / total
        r.lake = 100 * Double(lake) / total; r.gap = 100 * Double(gap) / total
        r.atCap = 100 * Double(cap) / total
        return r
    }
}

// MARK: - Sandfläche des Gürtels (Befund #174 „Sandwüste in der Schlinge")

extension RiverBeltRenderDiagnostics {

    /// Nächste Zentrumslinie je Zelle: Abstand in Kanalbreiten, Breite dort
    /// und geschätztes bankfull (tiefste Sohle im Querschnitt + Kanaltiefe,
    /// wie `Terrain.beltStamp` ohne Kolk-Schiefe). Reichweite `reach` Breiten.
    static func nearestLine(_ t: Terrain, reach: Double) -> (dist: [Double], width: [Double], zbf: [Double]) {
        let n = t.cfg.n, cnt = n * n
        var dist = [Double](repeating: .infinity, count: cnt)
        var width = [Double](repeating: 0, count: cnt)
        var zbf = [Double](repeating: 0, count: cnt)
        let depthK = t.cfg.meanderBeltDepthPerWidth * t.cfg.cellSize
        for ch in t.meander.channels where ch.nodes.count >= 3 {
            let c = ch.nodes.count
            var bw = [Double](repeating: 0, count: c), bf = [Double](repeating: 0, count: c)
            for i in 0..<c {
                let b = MeanderState.beltWidthCells(discharge: ch.discharge[i], config: t.cfg)
                bw[i] = b
                let w = 0.5 * b, p = ch.nodes[i]
                var lo = Double.infinity
                let r = Int(w.rounded(.up))
                let ci = Int(p.x.rounded()), cj = Int(p.z.rounded())
                for j in max(0, cj - r)...min(n - 1, max(0, cj + r)) {
                    for i2 in max(0, ci - r)...min(n - 1, max(0, ci + r)) {
                        let dx = Double(i2) - p.x, dz = Double(j) - p.z
                        if dx * dx + dz * dz <= (w + 0.5) * (w + 0.5) { lo = min(lo, t.h[j * n + i2]) }
                    }
                }
                bf[i] = (lo.isFinite ? lo : t.h[min(max(cj, 0), n - 1) * n + min(max(ci, 0), n - 1)]) + depthK * b
            }
            for i in 0..<(c - 1) {
                let a = ch.nodes[i], e = ch.nodes[i + 1]
                let b = 0.5 * (bw[i] + bw[i + 1])
                let R = reach * b
                let x0 = max(0, Int((min(a.x, e.x) - R).rounded(.down))), x1 = min(n - 1, Int((max(a.x, e.x) + R).rounded(.up)))
                let z0 = max(0, Int((min(a.z, e.z) - R).rounded(.down))), z1 = min(n - 1, Int((max(a.z, e.z) + R).rounded(.up)))
                guard x0 <= x1, z0 <= z1 else { continue }
                let sx = e.x - a.x, sz = e.z - a.z, l2 = max(1e-12, sx * sx + sz * sz)
                for j in z0...z1 {
                    for i2 in x0...x1 {
                        let px = Double(i2) - a.x, pz = Double(j) - a.z
                        let u = max(0, min(1, (px * sx + pz * sz) / l2))
                        let dx = px - u * sx, dz = pz - u * sz
                        let d = (dx * dx + dz * dz).squareRoot() / max(b, 1e-6)
                        let k = j * n + i2
                        if d < dist[k] {
                            dist[k] = d; width[k] = b
                            zbf[k] = bf[i] + u * (bf[i + 1] - bf[i])
                        }
                    }
                }
            }
        }
        return (dist, width, zbf)
    }

    /// Sandfläche aus `BarMaterial` gegen Gürtel und Kanal, verteilt nach
    /// Bankalter, Abstand zur Zentrumslinie (Kanalbreiten) und Höhe über
    /// bankfull (Kanaltiefen). RS_YEARS_LIST (Standard „2300,20000,100000"),
    /// RS_SEEDS; RS_CACHE = Ordner für Welt-Snapshots (spart den Lauf).
    func testBarSandExtentDiagnostic() throws {
        try skipUnlessMeasuring()
        let marks = (env["RS_YEARS_LIST"] ?? "2300,20000,100000").split(separator: ",").compactMap { Double($0) }
        let cache = env["RS_CACHE"]
        for seed in (env["RS_SEEDS"] ?? "1337,42").split(separator: ",").compactMap({ UInt32($0) }) {
            var t: Terrain?
            var start = 0.0
            for mark in marks {
                let path = cache.map { "\($0)/world-s\(seed)-\(Int(mark)).rsw" }
                if let p = path, FileManager.default.fileExists(atPath: p), let w = try? WorldSnapshot.read(from: p) {
                    t = w; start = w.years - mark
                } else {
                    if t == nil {
                        t = Terrain(config: SimConfig.production, seed: seed,
                                    settleYears: SimConfig.productionSettleYears)
                        start = t!.years
                    }
                    while t!.years < start + mark - 1e-6 { t!.step(dtYears: 100) }
                    if let p = path { _ = try WorldSnapshot.write(t!, to: p) }
                }
                Self.printSandExtent(t!, seed: seed, label: mark)
            }
        }
    }

    static func printSandExtent(_ t: Terrain, seed: UInt32, label: Double) {
        let n = t.cfg.n, cnt = n * n
        let f = BarMaterial.field(t)
        let near = nearestLine(t, reach: 12)
        let depthK = t.cfg.meanderBeltDepthPerWidth * t.cfg.cellSize
        var channelArea = 0.0
        for ch in t.meander.channels where ch.nodes.count >= 3 {
            for i in 0..<(ch.nodes.count - 1) {
                let a = ch.nodes[i], e = ch.nodes[i + 1]
                let len = ((e.x - a.x) * (e.x - a.x) + (e.z - a.z) * (e.z - a.z)).squareRoot()
                channelArea += len * 0.5 * (MeanderState.beltWidthCells(discharge: ch.discharge[i], config: t.cfg)
                                            + MeanderState.beltWidthCells(discharge: ch.discharge[i + 1], config: t.cfg))
            }
        }
        var bank = 0, sand = 0, sandAny = 0
        let ageEdges = [100.0, 300, 800, 1500, 3000, .infinity]
        let distEdges = [0.5, 1, 1.5, 2, 4, 8, .infinity]
        let hEdges = [-0.5, 0, 0.5, 1, 3, .infinity]
        var byAge = [Int](repeating: 0, count: ageEdges.count)
        var byDist = [Int](repeating: 0, count: distEdges.count)
        var byH = [Int](repeating: 0, count: hEdges.count)
        var vegSum = 0.0
        // Sim-Bewuchs auf Bank-Zellen nach Bankalter (alle Bänke, nicht nur Sand).
        var bankVeg = [Double](repeating: 0, count: ageEdges.count), bankN = [Int](repeating: 0, count: ageEdges.count)
        func bucket(_ v: Double, _ edges: [Double]) -> Int { edges.firstIndex { v < $0 } ?? edges.count - 1 }
        for k in 0..<cnt {
            if t.barAge[k] >= 0 {
                bank += 1
                let b = bucket(t.barAge[k], ageEdges)
                bankVeg[b] += t.veg[k]; bankN[b] += 1
            }
            if f.sand[k] > 0.05 { sandAny += 1 }
            guard f.sand[k] > 0.5 else { continue }
            sand += 1
            byAge[bucket(max(0, t.barAge[k]), ageEdges)] += 1
            byDist[bucket(near.dist[k], distEdges)] += 1
            let depth = depthK * max(near.width[k], 1e-6)
            byH[bucket(near.dist[k].isFinite ? (t.h[k] - near.zbf[k]) / depth : 99, hEdges)] += 1
            vegSum += t.veg[k]
        }
        func pct(_ a: [Int]) -> String {
            a.map { String(format: "%.0f", 100 * Double($0) / Double(max(1, sand))) }.joined(separator: "/")
        }
        print(String(format: "SAND s%d J%.0f | Sand>0,5 %d Zellen (>0,05: %d) | Bank %d → %.1f %% der Bank | Kanalfläche %.0f → Sand/Kanal %.2f | Sim-veg auf Sand %.2f",
                     seed, label, sand, sandAny, bank, 100 * Double(sand) / Double(max(1, bank)),
                     channelArea, Double(sand) / max(1, channelArea), vegSum / Double(max(1, sand))))
        print("  Alter <100/<300/<800/<1500/<3000/≥3000 J. (% Sand): " + pct(byAge))
        print("  Abstand <0,5/<1/<1,5/<2/<4/<8/≥8 Breiten (% Sand): " + pct(byDist))
        print("  Höhe über bankfull <−0,5/<0/<0,5/<1/<3/≥3 Tiefen (% Sand): " + pct(byH))
        // Junge Bank direkt am Gerinne (0,5–1,5 Breiten, jünger als 800 J.):
        // wie viel davon trägt Sand? (Gegenprobe: der Fix darf sie nicht leeren.)
        var young = 0, youngSand = 0
        for k in 0..<cnt where t.barAge[k] >= 0 && t.barAge[k] < 800 && near.dist[k] >= 0.5 && near.dist[k] < 1.5 {
            young += 1
            if f.sand[k] > 0.5 { youngSand += 1 }
        }
        // Gegenprobe der bankfull-Schätzung: frisch gestempelte Bank (< 100 J.)
        // am Gerinne liegt per Stempel höchstens auf `z_bf − barTop·D`.
        var fresh: [Double] = [], sandH: [Double] = []
        for k in 0..<cnt where near.dist[k] >= 0.5 && near.dist[k] < 1.5 {
            let depth = depthK * max(near.width[k], 1e-6)
            let rel = (t.h[k] - near.zbf[k]) / depth
            if t.barAge[k] >= 0 && t.barAge[k] < 100 { fresh.append(rel) }
            if f.sand[k] > 0.5 { sandH.append(rel) }
        }
        fresh.sort(); sandH.sort()
        func q(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? .nan : a[min(a.count - 1, Int(p * Double(a.count)))] }
        print(String(format: "  Höhe über bankfull (Tiefen D = %.5f Sim-Höhe bei Deckel-Breite), p10/p50/p90: frische Bank < 100 J. %.1f/%.1f/%.1f (%d) | Sand %.1f/%.1f/%.1f",
                     depthK * 2 * WaterRender.ribbonHalfWidthCapCells,
                     q(fresh, 0.1), q(fresh, 0.5), q(fresh, 0.9), fresh.count, q(sandH, 0.1), q(sandH, 0.5), q(sandH, 0.9)))
        // Dichtestes Bankfenster (40×40 Zellen, Bank jünger als 3000 J.) als
        // Blickpunkt für RS_TARGET (Weltkoordinaten).
        var bestCount = 0, bestI = 0, bestJ = 0
        for j0 in stride(from: 0, to: n - 40, by: 10) {
            for i0 in stride(from: 0, to: n - 40, by: 10) {
                var c = 0
                for j in j0..<(j0 + 40) { for i in i0..<(i0 + 40) {
                    let a = t.barAge[j * n + i]
                    if a >= 0 && a < 3000 { c += 1 }
                }}
                if c > bestCount { bestCount = c; bestI = i0 + 20; bestJ = j0 + 20 }
            }
        }
        let cs = t.cfg.cellSize, half = t.cfg.world / 2
        print(String(format: "  junge Bank am Gerinne (0,5–1,5 Br., < 800 J.) %d Zellen, davon Sand %.0f %% | dichteste junge Bank um Zelle (%d, %d) = RS_TARGET %.1f,%.1f",
                     young, 100 * Double(youngSand) / Double(max(1, young)), bestI, bestJ,
                     Double(bestI) * cs - half, Double(bestJ) * cs - half))
        print("  Sim-veg auf Bank nach Alter <100/<300/<800/<1500/<3000/≥3000: "
              + zip(bankVeg, bankN).map { String(format: "%.2f(%d)", $0 / Double(max(1, $1)), $1) }.joined(separator: " "))
    }
}
