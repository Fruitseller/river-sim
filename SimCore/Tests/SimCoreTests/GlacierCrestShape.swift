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
        // Höhenverteilung über der Firn-Grenze: Zellen je 0,01-Klasse ab 0,6, Maximum,
        // Anteil des Landes über der Grenze (die Kennzahl „keine harte Decke").
        do {
            let firnL = Glacier.firnLine(t.cfg)
            var hist = [Int](repeating: 0, count: 31)
            var over = 0
            for v in land { if v > firnL { over += 1 }; let b = Int((v - 0.6) * 100); if b >= 0 && b < 31 { hist[b] += 1 } }
            var line = ""
            for b in 0..<31 where hist[b] > 0 { line += String(format: " %.2f:%d", 0.6 + Double(b) * 0.01, hist[b]) }
            print(String(format: "HOEHE %@ | max %.4f | Land über Firn %.2f %% |%@", label, land.last!, 100 * Double(over) / Double(land.count), line))
        }
        // Wände: Anteil der Zellen über 0,55 mit Weltsteigung > 1,8 / > 2,5 (Bett), und
        // wie viele davon am Eisrand liegen (Eis oder Eis im Umkreis 3).
        do {
            let ss = 2 * RenderContract.heightScale / t.cfg.cellSize
            var hiN = 0, w18 = 0, w25 = 0, edge = 0
            for j in 5..<(n-5) { for i in 5..<(n-5) {
                let k = j*n+i
                guard t.h[k] > 0.55 else { continue }
                hiN += 1
                let w = Terrain.macroSlope(t.h, k, n) * ss
                if w > 1.8 { w18 += 1 }
                if w > 2.5 {
                    w25 += 1
                    if t.ice.count == n*n {
                        var near = false
                        for dj in -3...3 { for di in -3...3 where t.ice[k + dj*n + di] > t.cfg.iceMinThickness { near = true } }
                        if near { edge += 1 }
                    }
                }
            } }
            print(String(format: "WAND %@ | über 0,55: %d Zellen, Steigung >1,8: %.1f %%, >2,5: %.1f %% (davon am Eisrand ≤3: %.0f %%)",
                         label, hiN, 100*Double(w18)/Double(max(1,hiN)), 100*Double(w25)/Double(max(1,hiN)), 100*Double(edge)/Double(max(1,w25))))
        }
        // Tafel (Seed 20, Fenster x 200–290, z 355–380 bei n = 720): Bett-Spannweite
        // und längster Lauf (entlang x) mit Höhensprung < 0,0015 über 0,6.
        if n == 720 {
            var hmax = 0.0, run = 0, best = 0, aboveFirn = 0, plateau = 0
            let firnL = Glacier.firnLine(t.cfg)
            var rowSpan = ""
            for j in 355...380 {
                run = 0
                for i in 200...290 {
                    let k = j*n+i
                    hmax = max(hmax, t.h[k])
                    if t.h[k] > firnL { aboveFirn += 1 }
                    if t.h[k] > 0.625 && t.h[k] < 0.640 { plateau += 1 }
                    if t.h[k] > 0.6 && i > 200 && abs(t.h[k] - t.h[k-1]) < 0.0015 { run += 1; best = max(best, run) } else { run = 0 }
                }
            }
            var lo = 9.0, hi = 0.0
            for i in 200...290 { let v = t.h[370*n+i]; lo = min(lo, v); hi = max(hi, v) }
            rowSpan = String(format: "z370: %.3f…%.3f", lo, hi)
            if ProcessInfo.processInfo.environment["RS_ROW"] != nil {
                var line = "ROW z370 h:", il = "ROW z370 ice:"
                for i in stride(from: 200, through: 290, by: 3) { line += String(format: " %.3f", t.h[370*n+i]); il += String(format: " %.3f", t.ice[370*n+i]) }
                print(line); print(il)
            }
            print(String(format: "TAFEL %@ | Fenster max h %.4f | längster flacher Lauf %d Zellen | Zellen über Firn-Grenze %d, auf 0,625…0,640 %d | %@", label, hmax, best, aboveFirn, plateau, rowSpan))
        }
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
    /// **Wächter: Gipfel über der Firn-Grenze bleiben stehen** (Issue #174,
    /// Lawinen-Abgang des Firns, `docs/glacier-measurements.md` §M): ohne den
    /// Abgang steht auf jedem Gipfel über der Grenze Firn, das Eis schleift ihn
    /// bis knapp darunter, und das Gelände staut sich dort zu Tafeln
    /// (Seed 1337: Maximum 0,670 statt 0,752 des eisfreien Arms, harte Decke bei
    /// 0,65; Seed 20: 0,660 statt 0,727). Mit dem Abgang liegen beide Seeds beim
    /// eisfreien Arm (0,7525 / 0,7273). Gemessen wird gegen den eisfreien Arm
    /// derselben Welt (`iceEnabled = false`): Maximum und Landanteil über der
    /// Grenze. Produktion, 20 × 1000 Jahre; Schranken trennen die beiden
    /// Zustände (ohne Abgang 86 / 88 % und 31 / 27 %), sie sind kein Präzisionsmaß.
    func testProductionPeaksStandAboveTheFirnLine() {
        for seed: UInt32 in [1337, 20] {
            var free = SimConfig.production; free.iceEnabled = false
            let arms = [free, SimConfig.production].map { c -> Terrain in
                let t = Terrain(config: c, seed: seed, settleYears: SimConfig.productionSettleYears)
                let start = t.years
                while t.years < start + 20_000 - 1e-6 { t.step(dtYears: 1000) }
                return t
            }
            let sea = SimConfig.production.sea
            let firn = Glacier.firnLine(SimConfig.production)
            let maxFree = arms[0].h.max()!, maxIce = arms[1].h.max()!
            XCTAssertGreaterThan((maxIce - sea) / (maxFree - sea), 0.95,
                                 "seed \(seed): Gipfel mit Eis \(maxIce) gegen \(maxFree) ohne Eis — Eis kappt die Gipfel")
            let over = arms.map { t in t.h.filter { $0 > firn }.count }
            XCTAssertGreaterThan(Double(over[1]), 0.5 * Double(over[0]),
                                 "seed \(seed): Land über der Firn-Grenze \(over[1]) gegen \(over[0]) ohne Eis")
            XCTAssertGreaterThan(arms[1].ice.filter { $0 > arms[1].cfg.iceMinThickness }.count, 100,
                                 "seed \(seed): die Gipfel stehen, aber es gibt kein Eis mehr")
        }
    }
    /// Profil quer über den Kamm (Issue #174, §M): in der Welt OHNE Abgang den
    /// längsten flachen Lauf über 0,6 suchen (die Tafel) und an dessen Mitte die
    /// Höhe quer dazu (entlang z) in drei Armen drucken: ohne Abgang, mit Abgang,
    /// eisfrei — Bett-Höhe, Eis und Weltsteigung je dritte Zelle.
    ///
    ///     RS_MEASURE=1 RS_SEEDS=1337 swift test … --filter testCrestProfileDiagnostic
    func testCrestProfileDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let seeds = (env["RS_SEEDS"] ?? "1337").split(separator: ",").compactMap { UInt32($0) }
        for seed in seeds {
            let arms = ["avhi=0", "base", "ice=0"].map { v -> Terrain in
                let t = Terrain(config: Glacier.variant(v, of: SimConfig.production), seed: seed,
                                settleYears: SimConfig.productionSettleYears)
                let start = t.years
                while t.years < start + 20_000 - 1e-6 { t.step(dtYears: 1000) }
                return t
            }
            let n = arms[0].cfg.n
            let h0 = arms[0].h
            var best = 0, bi = 0, bj = 0
            for j in 5..<(n-5) {
                var run = 0
                for i in 6..<(n-5) {
                    if h0[j*n+i] > 0.6 && abs(h0[j*n+i] - h0[j*n+i-1]) < 0.0015 { run += 1
                        if run > best { best = run; bi = i - run / 2; bj = j }
                    } else { run = 0 }
                }
            }
            print("PROFIL s\(seed): längster flacher Lauf ohne Abgang \(best) Zellen bei i≈\(bi), j=\(bj)")
            let ss = 2 * RenderContract.heightScale / arms[0].cfg.cellSize
            for (name, t) in zip(["ohne Abgang", "mit Abgang", "eisfrei"], arms) {
                var hl = "", il = "", sl = ""
                for dj in stride(from: -30, through: 30, by: 3) {
                    let k = (bj + dj) * n + bi
                    hl += String(format: " %.3f", t.h[k]); il += String(format: " %.3f", t.ice.count == n*n ? t.ice[k] : 0)
                    sl += String(format: " %.1f", Terrain.macroSlope(t.h, k, n) * ss)
                }
                print("PROFIL \(name) h:\(hl)\nPROFIL \(name) Eis:\(il)\nPROFIL \(name) Steigung:\(sl)")
            }
        }
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
                do {
                    let nn = t.cfg.n, ss = 2 * RenderContract.heightScale / t.cfg.cellSize
                    var above = 0, s07 = 0, s10 = 0, s14 = 0
                    for j in 2..<(nn-2) { for i in 2..<(nn-2) {
                        let k = j*nn+i
                        guard t.h[k] > firn else { continue }
                        above += 1
                        let w = Terrain.macroSlope(t.h, k, nn) * ss
                        if w > 0.7 { s07 += 1 }; if w > 1.0 { s10 += 1 }; if w > 1.4 { s14 += 1 }
                    } }
                    print(String(format: "STEIL s%d | über Firn %d Zellen: Weltsteigung >0,7 %.0f %%, >1,0 %.0f %%, >1,4 %.0f %%",
                                 seed, above, 100*Double(s07)/Double(max(1,above)), 100*Double(s10)/Double(max(1,above)), 100*Double(s14)/Double(max(1,above))))
                }
                let start = t.years
                while t.years < start + 20000 - 1e-6 { t.step(dtYears: dt) }
                var mass = 0.0; for k in 0..<t.cfg.count { mass += t.ice[k] }
                stats(t, String(format: "s%d %@ dt%.0f Masse %.1f", seed, v, dt, mass))
            } }
        }
    }
}
