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
    /// Druckt die Kennzahlen und gibt die drei Abnahme-Größen zurück: flacher
    /// Anteil der obersten 5 % des Landes, Zackigkeit, Eisfläche als Landanteil.
    @discardableResult
    func stats(_ t: Terrain, _ label: String) -> (flat: Double, jag: Double, iceShare: Double) {
        let n = t.cfg.n, sea = t.cfg.sea
        var land: [Double] = []
        for k in 0..<(n*n) where t.h[k] > sea { land.append(t.h[k]) }
        land.sort()
        let p = { (q: Double) in land[Int(q * Double(land.count - 1))] }
        let hi = p(0.95)
        var flatHigh = 0, high = 0, iceHigh = 0, iceCells = 0
        var flatIce = 0, flatPit = 0, flatSed = 0.0, pitDepth = 0.0, flatMargin = 0
        let slopeScale = 2 * RenderContract.heightScale / t.cfg.cellSize
        for j in 2..<(n-2) { for i in 2..<(n-2) {
            let k = j*n+i
            if t.ice.count == n*n && t.ice[k] > t.cfg.iceMinThickness { iceCells += 1 }
            guard t.h[k] >= hi else { continue }
            high += 1
            if t.ice.count == n*n && t.ice[k] > t.cfg.iceMinThickness { iceHigh += 1 }
            if Terrain.macroSlope(t.h, k, n) * slopeScale < 0.15 {
                flatHigh += 1
                if t.ice.count == n*n && t.ice[k] > t.cfg.iceMinThickness { flatIce += 1 }
                flatSed += t.sed[k]
                if t.hf[k] - t.h[k] > 1e-4 { flatPit += 1; pitDepth += t.hf[k] - t.h[k] }
                if t.ice.count == n*n && t.ice[k] <= t.cfg.iceMinThickness {
                    var near = false
                    for dj in -3...3 { for di in -3...3 {
                        let q = k + dj*n + di
                        if q >= 0 && q < n*n && t.ice[q] > t.cfg.iceMinThickness { near = true }
                    } }
                    if near { flatMargin += 1 }
                }
            }
        } }
        if flatHigh > 0 {
            print(String(format: "FLACH %@ | unter Eis %.0f %%, Eisrand ≤3 %.0f %% | Senke (hf>h) %.0f %%, mittl. Tiefe %.4f | mittl. Sediment %.4f",
                         label, 100 * Double(flatIce) / Double(flatHigh),
                         100 * Double(flatMargin) / Double(flatHigh),
                         100 * Double(flatPit) / Double(flatHigh), pitDepth / Double(max(1, flatPit)),
                         flatSed / Double(flatHigh)))
        }
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
        print(String(format: "MESA %@ | max %.4f p99 %.4f p95 %.4f p50 %.4f | top5%%: flach(<0,15) %.1f %%, unter Eis %.1f %% | Eiszellen %d (%.2f %% des Landes)",
                     label, land.last!, p(0.99), hi, p(0.5), 100*Double(flatHigh)/Double(high), 100*Double(iceHigh)/Double(high), iceCells,
                     100 * Double(iceCells) / Double(land.count)))
        // Schnee im Bild liest `Terrain.snowCover` (Schneefeld, nicht Eis): Landanteile
        // mit sichtbarer Decke (> 0.05) und in der Rampe (> `snowBandCoverStart`).
        var vis = 0, ramp = 0
        for k in 0..<(n * n) where t.h[k] > sea {
            let cov = t.snowCover(k)
            if cov > 0.05 { vis += 1 }
            if cov > t.cfg.snowBandCoverStart { ramp += 1 }
        }
        print(String(format: "SCHNEE %@ | Deckung > 0,05: %.2f %% des Landes | Rampe: %.2f %%",
                     label, 100 * Double(vis) / Double(land.count), 100 * Double(ramp) / Double(land.count)))
        fflush(stdout)
        return (Double(flatHigh) / Double(max(1, high)), jag / Double(max(1, jagN)),
                Double(iceCells) / Double(max(1, land.count)))
    }

    /// Anteil des Landes über der Firn-Grenze des Eises
    /// (`sea + (T₀ − iceFirnTemp)/Γ`).
    func firnShare(_ t: Terrain) -> Double {
        let c = t.cfg, firn = Glacier.firnLine(c)
        let land = t.h.filter { $0 > c.sea }.count
        return Double(t.h.filter { $0 > firn }.count) / Double(max(1, land))
    }

    /// **Wächter der Produktions-Kalibrierung** (Issue #174, Nachkalibrierung der
    /// Firn-Grenze, `docs/glacier-measurements.md` §L): auf der Produktions-Welt
    /// (Seed 1337, Einlauf der Brücke, dt 1000 wie der `RS_STEP`-Vorlauf) liegt
    /// bei der Generierung wieder etwa der Landanteil von #35 über der Grenze, und
    /// 20.000 Jahre später trägt der Kamm Kar- und Talgletscher statt einer
    /// Eiskappe. Gemessen: 1,23 % über der Grenze, Eis 1,39 % des Landes, flach
    /// 2,7 % der obersten 5 % (mit 11 °C: 5,2 % / 4,1 % / 10,3 %, die Kappe).
    /// Schranken mit reichlich Luft: der Wächter trennt die beiden Zustände, er
    /// ist kein Präzisionsmaß.
    func testProductionCrestCarriesGlaciersNotACap() {
        let t = Terrain(config: .production, seed: 1337, settleYears: SimConfig.productionSettleYears)
        let share = firnShare(t)
        XCTAssertGreaterThan(share, 0.008, "kaum Land über der Firn-Grenze: kein Nährgebiet")
        XCTAssertLessThan(share, 0.022, "zu viel Land über der Firn-Grenze (#35: ~1,5 %): Eiskappe")
        let start = t.years
        while t.years < start + 20_000 - 1e-6 { t.step(dtYears: 1000) }
        let m = stats(t, "wächter s1337 dt1000")
        XCTAssertGreaterThan(m.iceShare, 0.005, "kein Eis auf der Produktions-Welt")
        XCTAssertLessThan(m.iceShare, 0.03, "Eis als Kappe statt als Kar- und Talgletscher")
        XCTAssertLessThan(m.flat, 0.06, "die Gipfelzone ist zur Tafel geworden")
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
                let c = Glacier.variant(v, of: SimConfig.production)
                let t = Terrain(config: c, seed: seed, settleYears: SimConfig.productionSettleYears)
                let firn = Glacier.firnLine(c)
                print(String(format: "FIRN s%d %@ | h %.4f | Land darüber %.2f %%", seed, v, firn, 100 * firnShare(t)))
                let start = t.years
                while t.years < start + 20000 - 1e-6 { t.step(dtYears: dt) }
                var mass = 0.0; for k in 0..<t.cfg.count { mass += t.ice[k] }
                stats(t, String(format: "s%d %@ dt%.0f Masse %.1f", seed, v, dt, mass))
            } }
        }
    }
}
