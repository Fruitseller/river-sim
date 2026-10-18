import XCTest
@testable import SimCore

// Kalibrier-Werkzeuge des Mäandergürtels (Issue #174, Paket B), alle hinter
// RS_MEASURE. Befunde und Messreihen: docs/zielbild-measurements.md § Paket B.
//
// - testBeltVariantsDiagnostic: Produktionswelt bis Jahr 20.000 mit
//   Parameter-Varianten, Kennzahlen über alle Mäanderläufe
//   (`ZielbildMetrics.beltAll`). RS_SEED, RS_VARIANT="brake=2,avw=4,…",
//   RS_YEARS.
// - testBeltKernelDiagnostic: Migration OHNE Gelände (drei gerade Läufe mit
//   Rauschen) — die Wellenlängen-Wahl des Kerns isoliert, ohne Kopplung ans
//   Gelände. Dieselben Varianten-Schlüssel, dazu RS_PNG (Bild der Läufe).
// - testBeltRiverViewDiagnostic: Karten (PPM) der Produktionswelt bei Jahr
//   2.000/10.000/20.000 (RS_SHOTS) nach RS_OUT: Kanal blau, Bank gelb, Altarm
//   magenta (unter `WaterRender.oxbowMinimumNodes` Knoten cyan), wandernde
//   Läufe rot; dazu die Linien als Text (.txt) für vergrößerte Ausschnitte.
//   RS_SEED, RS_VARIANT.
// - testOxbowOriginDiagnostic: Größe und Herkunft jedes neuen Altarms.
final class MeanderBeltCalibration: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func config() -> SimConfig { Self.variantConfig() }

    /// Produktions-Config mit den Varianten aus RS_VARIANT (auch gelesen von
    /// `ZielbildBaseline.testZielbildMeanderTimeMeanDiagnostic`).
    static func variantConfig() -> SimConfig {
        var c = SimConfig.production
        for kv in (ProcessInfo.processInfo.environment["RS_VARIANT"] ?? "").split(separator: ",") where kv.contains("=") {
            let p = kv.split(separator: "=")
            guard let v = Double(p[1]) else { continue }
            switch p[0] {
            case "rate": c.meanderBeltRate = v
            case "noise": c.meanderBeltNoise = v
            case "kernel": c.meanderBeltKernelWidths = v
            case "local": c.meanderBeltLocalWeight = v
            case "up": c.meanderBeltUpstreamWeight = v
            case "down": c.meanderBeltDownstreamWeight = v
            case "prof": c.meanderBeltProfileWidths = v
            case "gain": c.meanderBeltPoolGain = v
            case "brake": c.meanderBeltBrakeDepths = v
            case "minq": c.meanderBeltMinCells = v
            case "neck": c.meanderBeltNeckWidths = v
            case "chw": c.meanderChuteWidths = v
            case "chl": c.meanderChuteLoopRatio = v
            case "loop": c.meanderBeltMaxLoopWidths = v
            case "s0": c.meanderBeltSinuosityStart = v
            case "s1": c.meanderBeltSinuosityFull = v
            case "skew": c.meanderBeltPoolSkew = v
            case "relax": c.meanderBeltRelaxYears = v
            case "depth": c.meanderBeltDepthPerWidth = v
            case "chq": c.meanderChuteMinCells = v
            case "braid": c.braidingEnabled = v > 0
            case "coup": c.meanderBeltCoupling = v > 0
            case "cadence": c.meanderBeltCouplingYears = v
            case "symmetric": c.meanderBeltSymmetricStamp = v > 0
            case "slack": c.meanderBeltCouplingSlackCells = v
            case "avw": c.meanderBeltAvulsionWidths = v
            case "avd": c.meanderBeltAvulsionDepths = v > 0 ? v : .infinity
            case "avy": c.meanderBeltAvulsionYears = v
            case "abw": c.meanderBeltAbandonMinWidths = v
            case "drops": c.hydraulicPerYear = v
            default: XCTFail("unbekannter Varianten-Schlüssel \(p[0])")
            }
        }
        return c
    }

    func testBeltVariantsDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = env["RS_SEED"].flatMap { UInt32($0) } ?? 1337
        let years = env["RS_YEARS"].flatMap { Double($0) } ?? 20_000
        let t = Terrain(config: config(), seed: seed, settleYears: SimConfig.productionSettleYears)
        var swept = [Bool](repeating: false, count: t.cfg.count)
        let every = env["RS_EVERY"].flatMap { Double($0) }
        // Mittel über die Stützstellen ab der Hälfte des Laufs, alle 2000 Jahre:
        // ein Einzelzeitpunkt ist chaotisch.
        var avg = [Double](repeating: 0, count: 9), nAvg = 0.0, nLam = 0.0, nAsym = 0.0, nRaw = 0.0, nRawA = 0.0
        while t.years < years - 1e-6 {
            t.step(dtYears: 1000); ZielbildMetrics.markSwept(t, &swept)
            if t.years >= 0.5 * years - 1e-6, Int(t.years) % 2000 == 0 {
                let lf = ZielbildMetrics.landform(t)
                ZielbildMetrics.rawInflections = true
                let raw = ZielbildMetrics.beltAll(t, lowland: lf.lowland, swept: swept)
                ZielbildMetrics.rawInflections = false
                if raw.wavelength > 0 { avg[5] += raw.wavelengthPerWidth; nRaw += 1 }
                if raw.asymmetry > 0 { avg[6] += raw.asymmetry; nRawA += 1 }
                avg[7] += raw.beltPerAmplitude
                let a = ZielbildMetrics.beltAll(t, lowland: lf.lowland, swept: swept)
                let o = ZielbildMetrics.belt(t, lowland: lf.lowland, swept: swept, channel: RiverChannel(nodes: [], discharge: []))
                avg[0] += a.sinuosity; nAvg += 1
                if a.wavelength > 0 { avg[1] += a.wavelengthPerWidth; nLam += 1 }
                if a.asymmetry > 0 { avg[2] += a.asymmetry; nAsym += 1 }
                avg[3] += Double(o.openLowlandOxbows); avg[4] += a.beltPerAmplitude
                avg[8] += Double(o.wetLowlandOxbows)
            }
            if let e = every, Int(t.years) % Int(e) == 0, t.years < years - 1e-6 {
                let a = ZielbildMetrics.beltAll(t, lowland: ZielbildMetrics.landform(t).lowland, swept: swept)
                print(String(format: "BELT-T s%d %6.0f läufe %d sinu %.2f λ/b %.1f amp %.1f asym %.2f cut %d/%d",
                             seed, t.years, a.reachNodes, a.sinuosity, a.wavelengthPerWidth, a.amplitude,
                             a.asymmetry, t.meander.neckCutoffs, t.meander.chuteCutoffs))
            }
        }
        if env["RS_DETAIL"] != nil { detail(t) }
        if env["RS_WAVES"] != nil { waves(t) }
        if env["RS_OXBOW"] != nil {
            let n = t.cfg.n, d = t.cfg.meanderBeltDepthPerWidth * t.cfg.cellSize * 6.4
            for (oi, ox) in t.meander.oxbows.enumerated() where t.meander.oxbowAge[oi] < WaterRender.oxbowVisibleYears && ox.count >= 20 {
                var hfW = 0, wlW = 0, depth = 0.0, rimMin = Double.infinity
                for p in ox {
                    let k = min(max(Int(p.z.rounded()), 0), n - 1) * n + min(max(Int(p.x.rounded()), 0), n - 1)
                    if t.hf[k] - t.h[k] > WaterRender.pondContourLo { hfW += 1 }
                    if t.waterLevel[k] - t.h[k] > WaterRender.pondContourLo { wlW += 1 }
                    depth += t.hf[k] - t.h[k]
                }
                // Umgebung: Ring 5 Zellen um den Mittelknoten
                let mid = ox[ox.count / 2]
                for a in stride(from: 0.0, to: 2 * .pi, by: 0.3) {
                    let hh = t.h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, mid.x + 5 * cos(a), mid.z + 5 * sin(a)) }
                    rimMin = min(rimMin, hh)
                }
                let km = min(max(Int(mid.z.rounded()), 0), n - 1) * n + min(max(Int(mid.x.rounded()), 0), n - 1)
                print(String(format: "  ALTARM alter %5.0f knoten %3d nass(hf) %3d nass(wl) %3d Ø teich %.2f D | Mitte: rim−h %.2f D", t.meander.oxbowAge[oi], ox.count, hfW, wlW, depth / Double(ox.count) / d, (rimMin - t.h[km]) / d))
            }
        }
        if env["RS_PROFILE"] != nil { profiles(t) }
        let lf = ZielbildMetrics.landform(t)
        let all = ZielbildMetrics.beltAll(t, lowland: lf.lowland, swept: swept)
        let main = ZielbildMetrics.belt(t, lowland: lf.lowland, swept: swept)
        print(String(format: "AVG s%d %-40@ sinu %.2f λ/b %.1f (roh %.1f) asym %.2f (roh %.2f) ox-offen %.1f nass %.1f b/a %.1f (roh %.1f)",
                     seed, env["RS_VARIANT"] ?? "base", avg[0] / max(1, nAvg), avg[1] / max(1, nLam), avg[5] / max(1, nRaw),
                     avg[2] / max(1, nAsym), avg[6] / max(1, nRawA), avg[3] / max(1, nAvg), avg[8] / max(1, nAvg),
                     avg[4] / max(1, nAvg), avg[7] / max(1, nAvg)))
        print(String(format: "BELT s%d %-30@ %6.0f läufe %d sinu %.2f λ/b %.1f amp %.1f b/a %.1f asym %.2f | ox %d/%d cut %d/%d sub %d",
                     seed, env["RS_VARIANT"] ?? "base", t.years, all.reachNodes, all.sinuosity,
                     all.wavelengthPerWidth, all.amplitude, all.beltPerAmplitude, all.asymmetry,
                     main.openLowlandOxbows, main.lowlandOxbows, t.meander.neckCutoffs,
                     t.meander.chuteCutoffs, t.beltSubsteps))
    }

    /// Trennt Kern und Kopplung: die wandernden Läufe einer Produktionswelt
    /// (Jahr RS_START, Standard 3000) laufen OHNE Stempel weiter, einmal auf dem
    /// eingefrorenen Gelände, einmal auf einer Ebene. RS_YEARS Jahre.
    func testBeltIsolationDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = env["RS_SEED"].flatMap { UInt32($0) } ?? 1337
        let start = env["RS_START"].flatMap { Double($0) } ?? 3000
        let years = env["RS_YEARS"].flatMap { Double($0) } ?? 20_000
        let c = config()
        let t = Terrain(config: c, seed: seed, settleYears: SimConfig.productionSettleYears)
        while t.years < start - 1e-6 { t.step(dtYears: 1000) }
        let h = t.h, n = c.n
        let frozen: (MeanderNode) -> Double = { p in h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, p.x, p.z) } }
        let plain: (MeanderNode) -> Double = { p in c.sea + 0.05 - p.x * 1e-7 }
        for (name, hAt) in [("gelaende", frozen), ("ebene", plain)] as [(String, (MeanderNode) -> Double)] {
            let m = MeanderState()
            m.channels = t.meander.channels.filter { MeanderState.migrates($0, c) && $0.nodes.count >= 60 }
            if let q = env["RS_UNIFORMQ"].flatMap({ Double($0) }) {
                for i in m.channels.indices { m.channels[i].discharge = Array(repeating: q, count: m.channels[i].nodes.count) }
            }
            for ch in m.channels {
                let g = MeanderState.beltGeometry(ch, config: c, heightAt: hAt)
                let (r, er) = m.beltRatesAndErodibility(ch, g, config: c, heightAt: hAt)
                let mob = g.mob.filter { $0 > 0 }.count
                print(String(format: "ISO0 %@ knoten %d len %.0f q %.0f..%.0f mobil %d Ø er %.2f max|r| %.4f Ø|curv| %.4f Ø spacing %.2f",
                             name, ch.nodes.count, ch.length, ch.discharge.first ?? 0, ch.discharge.last ?? 0, mob,
                             er.reduce(0, +) / Double(max(1, mob)), r.map(abs).max() ?? 0,
                             g.curv.map(abs).reduce(0, +) / Double(ch.nodes.count), ch.length / Double(ch.nodes.count - 1)))
            }
            var y = 0.0
            while y < years - 1e-6 {
                let rate = m.beltMaxRate(config: c, heightAt: hAt)
                let nsub = max(1, min(256, Int((rate * 1000 / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
                for si in 0..<nsub {
                    m.migrateBelt(dt: 1000 / Double(nsub), time: y + Double(si) * 1000 / Double(nsub), config: c,
                                  heightAt: hAt)
                }
                y += 1000
                if let out = env["RS_PNG"], y >= years - 1e-6 {
                    var px = [UInt8](repeating: 0, count: n * n * 3)
                    let maxH = t.h.max() ?? 1
                    for k in 0..<(n * n) {
                        let v = UInt8(max(0, min(255, 40 + 215 * (t.h[k] - c.sea) / max(1e-9, maxH - c.sea))))
                        let col: (UInt8, UInt8, UInt8) = t.hf[k] <= c.sea ? (20, 40, 90) : (v, v, v)
                        px[3 * k] = col.0; px[3 * k + 1] = col.1; px[3 * k + 2] = col.2
                    }
                    for (ci, ch) in m.channels.enumerated() {
                        let g = MeanderState.beltGeometry(ch, config: c, heightAt: hAt)
                        for (i, p) in ch.nodes.enumerated() {
                            let x = Int(p.x.rounded()), z = Int(p.z.rounded())
                            guard x >= 0, z >= 0, x < n, z < n else { continue }
                            let k = 3 * (z * n + x)
                            let col: (UInt8, UInt8, UInt8) = g.mob[i] > 0 ? (255, UInt8(40 * (ci % 6)), 20) : (255, 255, 255)
                            px[k] = col.0; px[k + 1] = col.1; px[k + 2] = col.2
                        }
                    }
                    var data = Data("P6\n\(n) \(n)\n255\n".utf8); data.append(contentsOf: px)
                    try data.write(to: URL(fileURLWithPath: "\(out)/iso-\(name).ppm"))
                }
                if Int(y) % 4000 == 0 {
                    print(String(format: "ISO %@ %6.0f sinu %@ cut %d/%d", name, y,
                                 m.channels.map { String(format: "%.2f", $0.sinuosity) }.joined(separator: " "),
                                 m.neckCutoffs, m.chuteCutoffs))
                }
            }
        }
    }

    /// Querprofile an den schärfsten Bögen der wandernden Läufe: Höhe relativ
    /// zur Sohle in Kanaltiefen D, von innen (−) nach außen (+) in Halbbreiten.
    private func profiles(_ t: Terrain) {
        let c = t.cfg, n = c.n
        t.h.withUnsafeBufferPointer { hb in
            let ph = hb.baseAddress!
            let hAt: (MeanderNode) -> Double = { Terrain.bilinear(ph, n, $0.x, $0.z) }
            // Mittleres Profil über die Bögen der Asymmetrie-Messung (Lauf-Abschnitt
            // wie `beltAll`, |geglättete Krümmung| über dem Median), in D.
            var acc = [Double](repeating: 0, count: 9), cnt = 0.0
            for ch in t.meander.channels {
                guard let reach = ZielbildMetrics.lowlandReach(t, ch), reach.count >= 40 else { continue }
                let nodes = Array(ch.nodes[reach])
                let q = ch.discharge[reach].reduce(0, +) / Double(reach.count)
                let b = MeanderState.beltWidthCells(discharge: q, config: c), half = 0.5 * b
                let d = c.meanderBeltDepthPerWidth * c.cellSize * b
                let curv = ZielbildMetrics.smoothedCurvature(nodes, window: max(2, Int((b / c.meanderNodeSpacing).rounded())))
                let med = curv.map(abs).sorted()[curv.count / 2]
                for i in 1..<(nodes.count - 1) where abs(curv[i]) > med {
                    let a = nodes[i - 1], e = nodes[i + 1], m = nodes[i]
                    let tx = e.x - a.x, tz = e.z - a.z, tl = (tx * tx + tz * tz).squareRoot()
                    guard tl > 1e-9 else { continue }
                    let sgn = curv[i] > 0 ? -1.0 : 1.0
                    let ox = sgn * (-tz / tl), oz = sgn * (tx / tl)
                    var vals: [Double] = []
                    for eta in stride(from: -2.0, through: 2.0001, by: 0.5) {
                        vals.append(hAt(MeanderNode(x: m.x + ox * eta * half, z: m.z + oz * eta * half)))
                    }
                    let lo = vals[2...6].min()!
                    for j in 0..<9 { acc[j] += min(10, (vals[j] - lo) / d) }
                    cnt += 1
                }
            }
            print(String(format: "  PROFIL-MITTEL (%d Bögen, η −2…+2): %@", Int(cnt),
                         acc.map { String(format: "%5.2f", $0 / max(1, cnt)) }.joined(separator: " ")))
            var shown = 0
            for ch in t.meander.channels where MeanderState.migrates(ch, c) && ch.nodes.count >= 60 {
                let g = MeanderState.beltGeometry(ch, config: c, heightAt: hAt)
                let order = ch.nodes.indices.filter { g.mob[$0] > 0.3 }.sorted { abs(g.curv[$0]) > abs(g.curv[$1]) }
                for i in order.prefix(3) {
                    let b = g.width[i], w = 0.5 * b, d = c.meanderBeltDepthPerWidth * c.cellSize * b
                    let sgn = g.curv[i] > 0 ? -1.0 : 1.0
                    var vals: [Double] = []
                    for eta in stride(from: -2.0, through: 2.0001, by: 0.5) {
                        let s = eta * w
                        vals.append(hAt(MeanderNode(x: ch.nodes[i].x + sgn * g.nx[i] * s, z: ch.nodes[i].z + sgn * g.nz[i] * s)))
                    }
                    let lo = vals.min()!
                    print(String(format: "  PROFIL |κ|·b %.2f D %.4f: %@", abs(g.curv[i]) * b, d,
                                 vals.map { String(format: "%5.1f", ($0 - lo) / d) }.joined(separator: " ")))
                }
                shown += 1
                if shown >= 4 { break }
            }
        }
    }

    /// Je Lauf im Gürtel-Mittel: Halbwellen (Amplitude in Breiten, Sehne in Breiten).
    private func waves(_ t: Terrain) {
        let c = t.cfg
        for ch in t.meander.channels {
            guard let reach = ZielbildMetrics.lowlandReach(t, ch), reach.count >= 40 else { continue }
            let nodes = Array(ch.nodes[reach])
            let q = ch.discharge[reach].reduce(0, +) / Double(reach.count)
            let b = MeanderState.beltWidthCells(discharge: q, config: c)
            let win = max(2, Int((b / c.meanderNodeSpacing).rounded()))
            let curv = ZielbildMetrics.smoothedCurvature(nodes, window: win)
            var infl: [Int] = []
            for i in 1..<nodes.count where (curv[i - 1] < 0) != (curv[i] < 0) { infl.append(i) }
            var parts: [String] = []
            for k in 0..<max(0, infl.count - 1) {
                let a = nodes[infl[k]], e = nodes[infl[k + 1]]
                let dx = e.x - a.x, dz = e.z - a.z, l = (dx * dx + dz * dz).squareRoot()
                var m = 0.0
                for i in infl[k]...infl[k + 1] {
                    let p = nodes[i]
                    m = max(m, l > 1e-9 ? abs((p.x - a.x) * dz - (p.z - a.z) * dx) / l : dist(p, a))
                }
                parts.append(String(format: "%.1f/%.1f", m / b, l / b))
            }
            let len = (1..<nodes.count).reduce(0.0) { $0 + dist(nodes[$1 - 1], nodes[$1]) }
            print(String(format: "  WELLE reach %d (%.0f b) q %.0f b %.1f sinu %.2f infl %d | amp/sehne: %@", reach.count,
                         len / b, q, b, len / max(1e-9, dist(nodes[0], nodes[nodes.count - 1])), infl.count,
                         parts.joined(separator: " ")))
        }
    }

    /// Je wandernder Lauf: wie viel davon mobil ist und was die Rate bremst.
    private func detail(_ t: Terrain) {
        let c = t.cfg, n = c.n
        // Längsgefälle der mobilen Knoten in Kanaltiefen je Kanalbreite:
        // (1 − mob) · meanderFlatSlope / meanderBeltDepthPerWidth.
        var drops: [Double] = []
        t.h.withUnsafeBufferPointer { hb in
            let ph = hb.baseAddress!
            for ch in t.meander.channels where MeanderState.migrates(ch, c) && ch.nodes.count >= 3 {
                let g = MeanderState.beltGeometry(ch, config: c, heightAt: { Terrain.bilinear(ph, n, $0.x, $0.z) })
                for i in ch.nodes.indices where g.mob[i] > 0 { drops.append((1 - g.mob[i]) * c.meanderFlatSlope / c.meanderBeltDepthPerWidth) }
            }
        }
        drops.sort()
        if !drops.isEmpty {
            let q = { (f: Double) in drops[min(drops.count - 1, Int(f * Double(drops.count)))] }
            print(String(format: "  GEFÄLLE mobile Knoten %d: D je Breite p10 %.2f p50 %.2f p90 %.2f; Anteil < 0,5 D/b: %.0f %%",
                         drops.count, q(0.1), q(0.5), q(0.9), 100 * Double(drops.filter { $0 < 0.5 }.count) / Double(drops.count)))
        }
        t.h.withUnsafeBufferPointer { hb in
            let ph = hb.baseAddress!
            let hAt: (MeanderNode) -> Double = { Terrain.bilinear(ph, n, $0.x, $0.z) }
            for ch in t.meander.channels where MeanderState.migrates(ch, c) && ch.nodes.count >= 3 {
                let g = MeanderState.beltGeometry(ch, config: c, heightAt: hAt)
                let (r, er) = t.meander.beltRatesAndErodibility(ch, g, config: c, heightAt: hAt)
                var mobN = 0, braked = 0, sMob = 0.0, sRatio = 0.0, sRate = 0.0
                for i in ch.nodes.indices where g.mob[i] > 0 && ch.discharge[i] >= c.meanderBeltMinCells {
                    mobN += 1; sMob += g.mob[i]; sRatio += er[i] / g.mob[i]; sRate += abs(r[i])
                    if er[i] < 0.5 * g.mob[i] { braked += 1 }
                }
                let reach = ZielbildMetrics.lowlandReach(t, ch)
                var sinu = 1.0
                if let rr = reach, rr.count > 2 {
                    let nodes = Array(ch.nodes[rr])
                    var len = 0.0
                    for i in 1..<nodes.count { len += dist(nodes[i - 1], nodes[i]) }
                    sinu = len / max(1e-9, dist(nodes[0], nodes[nodes.count - 1]))
                }
                let m = Double(max(1, mobN))
                print(String(format: "  LAUF knoten %4d q %7.0f b %.1f | mobil %4d (reach %4d) Ø mob %.2f Ø brems %.2f gebremst %3.0f %% Ø |rate| %.4f | sinu %.2f",
                             ch.nodes.count, ch.discharge.last ?? 0, g.width.last ?? 0, mobN, reach?.count ?? 0,
                             sMob / m, sRatio / m, 100 * Double(braked) / m, sRate / m, sinu))
            }
        }
    }

    /// Streuung der Kern-Wächter über Rausch-Seeds (RS_SEEDS="1,2,…"): Cutoffs
    /// und Sinuosität nach 30.000 Jahren, Abstand dt 50 ↔ dt 1500 nach RS_DTYEARS.
    func testBeltKernelSpreadDiagnostic() throws {
        try skipUnlessMeasuring()
        let c = config()
        let flat: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }
        // Wie `MeanderBeltTests`: der lange Lauf trägt einen Lauf unter der
        // Chute-Schwelle (dort gibt es nur Hals-Cutoffs).
        func runs(_ seed: UInt32, long: Bool = false) -> MeanderState {
            let m = MeanderState()
            var rng = Mulberry32(seed: seed)
            for (ri, z0) in [150.0, 360, 570].enumerated() {
                var nodes: [MeanderNode] = []
                for i in 0..<400 { nodes.append(MeanderNode(x: 60 + Double(i) * 1.5, z: z0 + (rng.next() - 0.5) * 0.4)) }
                let q = long && ri == 2 ? 0.75 * c.meanderChuteMinCells : 20_000
                m.channels.append(RiverChannel(nodes: nodes, discharge: Array(repeating: q, count: 400)))
            }
            return m
        }
        func run(_ m: MeanderState, _ years: Double, _ dt: Double) {
            var y = 0.0
            while y < years - 1e-9 {
                let step = min(dt, years - y)
                let rate = m.beltMaxRate(config: c, heightAt: flat)
                let nsub = max(1, min(256, Int((rate * step / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
                for si in 0..<nsub {
                    m.migrateBelt(dt: step / Double(nsub), time: y + Double(si) * step / Double(nsub), config: c,
                                  heightAt: flat)
                }
                y += step
            }
        }
        let seeds = (env["RS_SEEDS"] ?? "7,1,2,3,4,5").split(separator: ",").compactMap { UInt32($0) }
        let dtYears = env["RS_DTYEARS"].flatMap { Double($0) } ?? 1500
        for seed in seeds {
            let m = runs(seed, long: true)
            run(m, env["RS_LONG"].flatMap { Double($0) } ?? 30_000, 1000)
            let loc = m.channels.map { MeanderBeltTests.maxLocalSinuosity($0, config: c) }.max() ?? 0
            let crossings = m.channels.map { MeanderBeltTests.selfCrossings($0) }.reduce(0, +)
            let l = runs(seed)
            run(l, 3000, 1000)
            let bw = MeanderState.beltWidthCells(discharge: 20_000, config: c)
            let lams = l.channels.map { ch -> Double in
                let curv = ZielbildMetrics.smoothedCurvature(ch.nodes, window: max(2, Int((bw / c.meanderNodeSpacing).rounded())))
                return ZielbildMetrics.bends(ch.nodes, curv: curv, width: bw, minAmplitudeWidths: 0).wavelength / bw
            }
            print("SPREAD seed \(seed) | λ/b nach 3000 J.: \(lams.map { String(format: "%.1f", $0) })")
            let a = runs(seed), b = runs(seed)
            run(a, dtYears, 50); run(b, dtYears, 1500)
            var acc = 0.0, cnt = 0.0, moved = 0.0
            for (ca, cb) in zip(a.channels, b.channels) {
                for p in ca.nodes {
                    acc += cb.nodes.map { dist($0, p) }.min()!; cnt += 1
                    moved = max(moved, abs(p.z - (ca.nodes.first?.z ?? p.z)))
                }
            }
            print(String(format: "SPREAD seed %d | lang: Hals %d Chute %d max Sinu %.2f örtlich %.2f Kreuzungen %d | dt %.0f J.: Abstand %.3f Auslenkung %.2f",
                         seed, m.neckCutoffs, m.chuteCutoffs, m.channels.map(\.sinuosity).max() ?? 0, loc, crossings, dtYears, acc / cnt, moved))
        }
    }

    func testBeltKernelDiagnostic() throws {
        try skipUnlessMeasuring()
        let c = config()
        let m = MeanderState()
        var rng = Mulberry32(seed: 7)
        for z0 in [150.0, 360, 570] {
            var nodes: [MeanderNode] = []
            // RS_LONGWAVE="A,λ": lange Anfangswelle (Zellen) wie die Talkurven einer D8-Trasse.
            let lw = (env["RS_LONGWAVE"] ?? "0,1").split(separator: ",").compactMap { Double($0) }
            for i in 0..<400 {
                let x = Double(i) * 1.5
                nodes.append(MeanderNode(x: 60 + x, z: z0 + (rng.next() - 0.5) * 0.4 + lw[0] * sin(2 * .pi * x / lw[1])))
            }
            m.channels.append(RiverChannel(nodes: nodes, discharge: Array(repeating: 20000, count: 400)))
        }
        let hAt: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }
        let end = env["RS_YEARS"].flatMap { Double($0) } ?? 80_000
        let b = MeanderState.beltWidthCells(discharge: 20000, config: c)
        var years = 0.0, sSum = 0.0, lSum = 0.0, nS = 0.0, maxSub = 0
        while years < end {
            let dt = min(env["RS_DT"].flatMap(Double.init) ?? 1000, end - years)
            let rate = m.beltMaxRate(config: c, heightAt: hAt)
            let nsub = max(1, min(256, Int((rate * dt / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
            maxSub = max(maxSub, nsub)
            for si in 0..<nsub {
                m.migrateBelt(dt: dt / Double(nsub), time: years + Double(si) * dt / Double(nsub), config: c, heightAt: hAt)
            }
            years += dt
            guard years >= 10_000, Int(years) % 2000 == 0 else { continue }
            for ch in m.channels {
                let win = max(2, Int((b / c.meanderNodeSpacing).rounded()))
                let curv = ZielbildMetrics.smoothedCurvature(ch.nodes, window: win)
                let lam = ZielbildMetrics.bends(ch.nodes, curv: curv, width: b).wavelength
                sSum += ch.sinuosity; lSum += lam / b; nS += 1
            }
            if env["RS_TRACE"] != nil {
                print(String(format: "KERN-T %6.0f sinu %@ cut %d/%d", years,
                             m.channels.map { String(format: "%.2f", $0.sinuosity) }.joined(separator: " "),
                             m.neckCutoffs, m.chuteCutoffs))
            }
        }
        if env["RS_WAVES"] != nil {
            for ch in m.channels {
                let win = max(2, Int((b / c.meanderNodeSpacing).rounded()))
                let curv = ZielbildMetrics.smoothedCurvature(ch.nodes, window: win)
                var infl: [Int] = []
                for i in (ch.nodes.count * 2 / 5)..<ch.nodes.count where (curv[i - 1] < 0) != (curv[i] < 0) { infl.append(i) }
                var parts: [String] = [], lam = 0.0
                for k in 0..<max(0, infl.count - 1) {
                    let a = ch.nodes[infl[k]], e = ch.nodes[infl[k + 1]]
                    let dx = e.x - a.x, dz = e.z - a.z, l = (dx * dx + dz * dz).squareRoot()
                    var mm = 0.0
                    for i in infl[k]...infl[k + 1] {
                        let p = ch.nodes[i]
                        mm = max(mm, l > 1e-9 ? abs((p.x - a.x) * dz - (p.z - a.z) * dx) / l : dist(p, a))
                    }
                    parts.append(String(format: "%.1f/%.1f", mm / b, l / b))
                }
                if infl.count >= 3 {
                    for k in 0..<(infl.count - 2) { lam += dist(ch.nodes[infl[k]], ch.nodes[infl[k + 2]]) }
                    lam /= Double(infl.count - 2) * b
                }
                print(String(format: "  KWELLE λ/b %.1f amp/sehne: %@", lam, parts.joined(separator: " ")))
            }
        }
        if let out = env["RS_PNG"] {
            let n = 720
            var px = [UInt8](repeating: 255, count: n * n * 3)
            func put(_ p: MeanderNode, _ r: UInt8, _ g: UInt8, _ bl: UInt8, _ rad: Int) {
                let x = Int(p.x.rounded()), z = Int(p.z.rounded())
                for dz in -rad...rad { for dx in -rad...rad {
                    let xx = x + dx, zz = z + dz
                    guard xx >= 0, zz >= 0, xx < n, zz < n else { continue }
                    let k = (zz * n + xx) * 3; px[k] = r; px[k + 1] = g; px[k + 2] = bl
                } }
            }
            for ox in m.oxbows { for p in ox { put(p, 200, 120, 40, 0) } }
            for ch in m.channels { for p in ch.nodes { put(p, 30, 80, 200, 2) } }
            var data = Data("P6\n\(n) \(n)\n255\n".utf8); data.append(contentsOf: px)
            try data.write(to: URL(fileURLWithPath: out))
        }
        print(String(format: "KERN %@ | Ø sinu %.2f Ø λ/b %.1f | cut %d/%d | maxSub %d",
                     env["RS_VARIANT"] ?? "base", nS > 0 ? sSum / nS : 0, nS > 0 ? lSum / nS : 0,
                     m.neckCutoffs, m.chuteCutoffs, maxSub))
    }

    /// Herkunft der Altarme bis RS_YEARS: je neuem Altarm Knotenzahl, Kanalbreite
    /// (Abfluss am Anschlussknoten des Laufs) und Bogenlänge in Breiten, als
    /// Verteilung ab 0/15/20/30/50/100 Knoten. Zeigte vor der
    /// Zeitmittel-Kalibrierung: die meisten Altarme waren Knicke von 3–5
    /// Breiten Bogenlänge an voll breiten Läufen.
    func testOxbowOriginDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = env["RS_SEED"].flatMap { UInt32($0) } ?? 42
        let years = env["RS_YEARS"].flatMap { Double($0) } ?? 100_000
        let t = Terrain(config: config(), seed: seed, settleYears: SimConfig.productionSettleYears)
        let n = t.cfg.n
        var rows: [(nodes: Int, b: Double, lenB: Double, chordB: Double, low: Bool)] = []
        while t.years < years - 1e-6 {
            t.step(dtYears: 1000)
            let lf = ZielbildMetrics.landform(t)
            for (oi, ox) in t.meander.oxbows.enumerated() where t.meander.oxbowAge[oi] == 0 {
                let p = ox[0]
                var best = Double.infinity, q = 0.0
                for ch in t.meander.channels { for (i, nd) in ch.nodes.enumerated() {
                    let d = dist(nd, p); if d < best { best = d; q = ch.discharge[i] } } }
                let b = MeanderState.beltWidthCells(discharge: q, config: t.cfg)
                var len = 0.0
                for i in 1..<ox.count { len += dist(ox[i - 1], ox[i]) }
                let cx = ox.reduce(0) { $0 + $1.x } / Double(ox.count), cz = ox.reduce(0) { $0 + $1.z } / Double(ox.count)
                let k = min(max(Int(cz.rounded()), 0), n - 1) * n + min(max(Int(cx.rounded()), 0), n - 1)
                rows.append((ox.count, b, len / b, dist(ox[0], ox[ox.count - 1]) / b, lf.lowland[k]))
            }
        }
        for lo in [0, 15, 20, 30, 50, 100] {
            let sel = rows.filter { $0.nodes >= lo }
            let bs = sel.map(\.b).sorted(), ls = sel.map(\.lenB).sorted()
            guard !sel.isEmpty else { continue }
            print(String(format: "ORIGIN s%d ab %3d Knoten: %3d Altarme, Tiefland %3d | b p50 %.1f (p10 %.1f p90 %.1f) | Länge/b p50 %.1f (p10 %.1f p90 %.1f)",
                         seed, lo, sel.count, sel.filter(\.low).count, bs[bs.count / 2], bs[bs.count / 10], bs[bs.count * 9 / 10],
                         ls[ls.count / 2], ls[ls.count / 10], ls[ls.count * 9 / 10]))
        }
        let small = rows.filter { $0.nodes < 20 }
        print("ORIGIN s\(seed) unter 20 Knoten nach b: " + [2.0, 3, 4, 5, 6, 7].map { lim in
            "b<\(Int(lim)): \(small.filter { $0.b < lim }.count)" }.joined(separator: " "))
    }

    func testBeltRiverViewDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = env["RS_SEED"].flatMap { UInt32($0) } ?? 1337
        let out = env["RS_OUT"] ?? "/tmp"
        let t = Terrain(config: config(), seed: seed, settleYears: SimConfig.productionSettleYears)
        let n = t.cfg.n
        for target in (env["RS_SHOTS"] ?? "2000,10000,20000").split(separator: ",").compactMap({ Double($0) }) {
            while t.years < target { t.step(dtYears: 1000) }
            var px = [UInt8](repeating: 0, count: n * n * 3)
            let maxH = t.h.max() ?? 1
            for k in 0..<(n * n) {
                let v = UInt8(max(0, min(255, 40 + 215 * (t.h[k] - t.cfg.sea) / max(1e-9, maxH - t.cfg.sea))))
                var c: (UInt8, UInt8, UInt8) = (v, v, v)
                if t.hf[k] <= t.cfg.sea { c = (20, 40, 90) }
                else if t.barAge[k] >= 0 { c = (230, 200, 90) }
                else if t.isChannel[k] { c = (60, 120, 230) }
                px[3 * k] = c.0; px[3 * k + 1] = c.1; px[3 * k + 2] = c.2
            }
            func put(_ p: MeanderNode, _ c: (UInt8, UInt8, UInt8)) {
                let x = Int(p.x.rounded()), z = Int(p.z.rounded())
                guard x >= 0, z >= 0, x < n, z < n else { return }
                let k = z * n + x; px[3 * k] = c.0; px[3 * k + 1] = c.1; px[3 * k + 2] = c.2
            }
            // Altarme: magenta ab `WaterRender.oxbowMinimumNodes` Knoten (der
            // Render zeigt sie), cyan darunter (unsichtbar); verblasst ab
            // `oxbowVisibleYears`.
            for (oi, ox) in t.meander.oxbows.enumerated() {
                let young = t.meander.oxbowAge[oi] < WaterRender.oxbowVisibleYears
                let col: (UInt8, UInt8, UInt8) = ox.count >= WaterRender.oxbowMinimumNodes
                    ? (young ? (255, 60, 255) : (140, 70, 140)) : (young ? (0, 255, 255) : (0, 130, 130))
                for p in ox { put(p, col) }
            }
            // Wandernde Läufe nach Mobilität: rot voll mobil, orange teilweise, weiß fest.
            t.h.withUnsafeBufferPointer { hb in
                let ph = hb.baseAddress!
                for ch in t.meander.channels where MeanderState.migrates(ch, t.cfg) && ch.nodes.count >= 3 {
                    let g = MeanderState.beltGeometry(ch, config: t.cfg, heightAt: { Terrain.bilinear(ph, n, $0.x, $0.z) })
                    for (i, p) in ch.nodes.enumerated() {
                        put(p, g.mob[i] > 0.5 ? (255, 20, 20) : g.mob[i] > 0 ? (255, 150, 0) : (255, 255, 255))
                    }
                }
            }
            var data = Data("P6\n\(n) \(n)\n255\n".utf8); data.append(contentsOf: px)
            try data.write(to: URL(fileURLWithPath: "\(out)/belt-\(seed)-\(Int(target)).ppm"))
            // Linien als Text für vergrößerte Ausschnitte (Knoten unter Zellauflösung).
            var txt = ""
            for (ci, ch) in t.meander.channels.enumerated() where ch.nodes.count >= 3 {
                let mig = MeanderState.migrates(ch, t.cfg) ? 1 : 0
                for (i, p) in ch.nodes.enumerated() {
                    txt += String(format: "C %d %d %.2f %.2f %.0f\n", ci, mig, p.x, p.z, ch.discharge[i])
                }
            }
            for (oi, ox) in t.meander.oxbows.enumerated() {
                for p in ox { txt += String(format: "O %d %.0f %.2f %.2f %d\n", oi, t.meander.oxbowAge[oi], p.x, p.z, ox.count) }
            }
            try txt.write(toFile: "\(out)/belt-\(seed)-\(Int(target)).txt", atomically: true, encoding: .utf8)
        }
    }
}
