import XCTest
@testable import SimCore

/// Kammform unter dem Gletscher (Issue #174, `docs/glacier-measurements.md`
/// § „Offener Befund: der stabile Transport macht den Kamm zur Tafel"):
/// Höhen-Perzentile, Anteil flacher Zellen und Zackigkeit der obersten 5 % des
/// Landes, Gipfelzahl, Eiszellen — Produktion, 20.000 Jahre.
///
///     RS_MEASURE=1 RS_VARIANTS="base;erode=1.25e-4" RS_DTS=100,1000 \
///         swift test … --filter testGlacierCrestShapeDiagnostic
///
/// `RS_OLD=1` misst zusätzlich gespeicherte Welten aus `/tmp/rs-cache`.
final class GlacierCrestShape: XCTestCase {
    func stats(_ t: Terrain, _ label: String) {
        let n = t.cfg.n, sea = t.cfg.sea
        var land: [Double] = []
        for k in 0..<(n*n) where t.h[k] > sea { land.append(t.h[k]) }
        land.sort()
        let p = { (q: Double) in land[Int(q * Double(land.count - 1))] }
        let hi = p(0.95)
        var flatHigh = 0, high = 0, iceHigh = 0, iceCells = 0
        let slopeScale = 2 * RenderContract.heightScale / t.cfg.cellSize
        for j in 2..<(n-2) { for i in 2..<(n-2) {
            let k = j*n+i
            if t.ice.count == n*n && t.ice[k] > t.cfg.iceMinThickness { iceCells += 1 }
            guard t.h[k] >= hi else { continue }
            high += 1
            if t.ice.count == n*n && t.ice[k] > t.cfg.iceMinThickness { iceHigh += 1 }
            if Terrain.macroSlope(t.h, k, n) * slopeScale < 0.15 { flatHigh += 1 }
        } }
        // Gipfel: lokale Maxima im 9×9-Fenster über p97; Zackigkeit: mittlere
        // |h − Mittel 9×9| über den Zellen über p95.
        let p97 = p(0.97)
        var peaks = 0, jag = 0.0, jagN = 0
        for j in 4..<(n-4) { for i in 4..<(n-4) {
            let k = j*n+i
            guard t.h[k] >= hi else { continue }
            var isMax = true, sum = 0.0
            for dj in -4...4 { for di in -4...4 {
                let q = t.h[k + dj*n + di]; sum += q
                if (di != 0 || dj != 0) && q >= t.h[k] { isMax = false }
            } }
            if isMax && t.h[k] >= p97 { peaks += 1 }
            jag += abs(t.h[k] - sum / 81); jagN += 1
        } }
        print(String(format: "GIPFEL %@ | Gipfel>p97 %d | Zackigkeit %.5f", label, peaks, jag / Double(max(1, jagN))))
        print(String(format: "MESA %@ | max %.4f p99 %.4f p95 %.4f p50 %.4f | top5%%: flach(<0,15) %.1f %%, unter Eis %.1f %% | Eiszellen %d",
                     label, land.last!, p(0.99), hi, p(0.5), 100*Double(flatHigh)/Double(high), 100*Double(iceHigh)/Double(high), iceCells))
    }
    func testGlacierCrestShapeDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let seeds = (env["RS_SEEDS"] ?? "1337,42,20").split(separator: ",").compactMap { UInt32($0) }
        let dts = (env["RS_DTS"] ?? "1000").split(separator: ",").compactMap { Double($0) }
        let variants = (env["RS_VARIANTS"] ?? "base").split(separator: ";").map(String.init)
        for seed in seeds {
            if env["RS_OLD"] != nil, let old = try? WorldSnapshot.read(from: "/tmp/rs-cache/world-s\(seed)-20000.rsw") { stats(old, "s\(seed) alt dt100") }
            for v in variants { for dt in dts {
                var c = SimConfig.production
                for kv in v.split(separator: ",") {
                    let p = kv.split(separator: "="); guard p.count == 2, let x = Double(p[1]) else { continue }
                    switch p[0] { case "erode": c.iceErodeK = x; case "firn": c.iceFirnPerSnowYear = x
                    case "turn": c.iceTurnoverYears = x; case "melt": c.iceMeltPerKYear = x; case "flow": c.iceFlowK = x
                    default: break }
                }
                let t = Terrain(config: c, seed: seed, settleYears: SimConfig.productionSettleYears)
                let start = t.years
                while t.years < start + 20000 - 1e-6 { t.step(dtYears: dt) }
                var mass = 0.0; for k in 0..<t.cfg.count { mass += t.ice[k] }
                stats(t, String(format: "s%d %@ dt%.0f Masse %.1f", seed, v, dt, mass))
            } }
        }
    }
}
