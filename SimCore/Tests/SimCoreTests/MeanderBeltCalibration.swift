import XCTest
@testable import SimCore

// Kalibrier-Werkzeuge des Mäandergürtels (Issue #174, Paket B), alle hinter
// RS_MEASURE. Befunde und Messreihen: docs/zielbild-measurements.md § Paket B.
//
// - testBeltVariantsDiagnostic: Produktionswelt bis Jahr 20.000 mit
//   Parameter-Varianten, Kennzahlen über alle Mäanderläufe
//   (`ZielbildMetrics.beltAll`). RS_SEED, RS_VARIANT="pull=0,brake=2,…",
//   RS_YEARS.
// - testBeltKernelDiagnostic: Migration OHNE Gelände (drei gerade Läufe mit
//   Rauschen) — die Wellenlängen-Wahl des Kerns isoliert, ohne Kopplung ans
//   Gelände. Dieselben Varianten-Schlüssel, dazu RS_PNG (Bild der Läufe).
// - testBeltRiverViewDiagnostic: Karten (PPM) der Produktionswelt bei Jahr
//   2.000/10.000/20.000 nach RS_OUT: Kanal blau, Bank gelb, Altarm magenta,
//   wandernde Läufe rot. RS_SEED, RS_VARIANT.
final class MeanderBeltCalibration: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Produktions-Config mit den Varianten aus RS_VARIANT.
    private func config() -> SimConfig {
        var c = SimConfig.production
        for kv in (env["RS_VARIANT"] ?? "").split(separator: ",") where kv.contains("=") {
            let p = kv.split(separator: "=")
            guard let v = Double(p[1]) else { continue }
            switch p[0] {
            case "rate": c.meanderBeltRate = v
            case "kernel": c.meanderBeltKernelWidths = v
            case "local": c.meanderBeltLocalWeight = v
            case "up": c.meanderBeltUpstreamWeight = v
            case "pull": c.meanderBeltPull = v
            case "deadband": c.meanderBeltPullDeadband = v
            case "brake": c.meanderBeltBrakeDepths = v
            case "coh": c.meanderBeltCohesion = v
            case "minq": c.meanderBeltMinCells = v
            case "neck": c.meanderBeltNeckWidths = v
            case "chw": c.meanderChuteWidths = v
            case "chl": c.meanderChuteLoopRatio = v
            case "loop": c.meanderBeltMaxLoopWidths = v
            case "s0": c.meanderBeltSinuosityStart = v
            case "s1": c.meanderBeltSinuosityFull = v
            case "skew": c.meanderBeltPoolSkew = v
            case "relax": c.meanderBeltRelaxYears = v
            case "braid": c.braidingEnabled = v > 0
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
        while t.years < years - 1e-6 { t.step(dtYears: 1000); ZielbildMetrics.markSwept(t, &swept) }
        let lf = ZielbildMetrics.landform(t)
        let all = ZielbildMetrics.beltAll(t, lowland: lf.lowland, swept: swept)
        let main = ZielbildMetrics.belt(t, lowland: lf.lowland, swept: swept)
        print(String(format: "BELT s%d %-30@ %6.0f läufe %d sinu %.2f λ/b %.1f amp %.1f b/a %.1f asym %.2f | ox %d/%d cut %d/%d sub %d",
                     seed, env["RS_VARIANT"] ?? "base", t.years, all.reachNodes, all.sinuosity,
                     all.wavelengthPerWidth, all.amplitude, all.beltPerAmplitude, all.asymmetry,
                     main.openLowlandOxbows, main.lowlandOxbows, t.meander.neckCutoffs,
                     t.meander.chuteCutoffs, t.beltSubsteps))
    }

    func testBeltKernelDiagnostic() throws {
        try skipUnlessMeasuring()
        let c = config()
        let m = MeanderState()
        var rng = Mulberry32(seed: 7)
        for z0 in [150.0, 360, 570] {
            var nodes: [MeanderNode] = []
            for i in 0..<400 { nodes.append(MeanderNode(x: 60 + Double(i) * 1.5, z: z0 + (rng.next() - 0.5) * 0.4)) }
            m.channels.append(RiverChannel(nodes: nodes, discharge: Array(repeating: 20000, count: 400)))
        }
        let hAt: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }
        let end = env["RS_YEARS"].flatMap { Double($0) } ?? 80_000
        let b = MeanderState.beltWidthCells(discharge: 20000, config: c)
        var years = 0.0, sSum = 0.0, lSum = 0.0, nS = 0.0, maxSub = 0
        while years < end {
            let dt = 1000.0
            let rate = m.beltMaxRate(config: c, heightAt: hAt, riparianAt: { _ in 0 })
            let nsub = max(1, min(256, Int((rate * dt / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
            maxSub = max(maxSub, nsub)
            for _ in 0..<nsub {
                m.migrateBelt(dt: dt / Double(nsub), config: c, heightAt: hAt, riparianAt: { _ in 0 })
            }
            years += dt
            guard years >= 10_000, Int(years) % 2000 == 0 else { continue }
            for ch in m.channels {
                let win = max(2, Int((b / c.meanderNodeSpacing).rounded()))
                let curv = ZielbildMetrics.smoothedCurvature(ch.nodes, window: win)
                var infl: [Int] = []
                for i in 1..<ch.nodes.count where (curv[i - 1] < 0) != (curv[i] < 0) { infl.append(i) }
                var lam = 0.0
                if infl.count >= 3 {
                    for k in 0..<(infl.count - 2) { lam += dist(ch.nodes[infl[k]], ch.nodes[infl[k + 2]]) }
                    lam /= Double(infl.count - 2)
                }
                sSum += ch.sinuosity; lSum += lam / b; nS += 1
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

    func testBeltRiverViewDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = env["RS_SEED"].flatMap { UInt32($0) } ?? 1337
        let out = env["RS_OUT"] ?? "/tmp"
        let t = Terrain(config: config(), seed: seed, settleYears: SimConfig.productionSettleYears)
        let n = t.cfg.n
        for target in [2000.0, 10_000, 20_000] {
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
            for ox in t.meander.oxbows { for p in ox { put(p, (200, 80, 200)) } }
            for ch in t.meander.channels where (ch.discharge.max() ?? 0) >= t.cfg.meanderBeltMinCells {
                for p in ch.nodes { put(p, (255, 20, 20)) }
            }
            var data = Data("P6\n\(n) \(n)\n255\n".utf8); data.append(contentsOf: px)
            try data.write(to: URL(fileURLWithPath: "\(out)/belt-\(seed)-\(Int(target)).ppm"))
        }
    }
}
