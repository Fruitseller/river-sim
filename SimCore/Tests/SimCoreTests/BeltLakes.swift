import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Messreihe zu Issue #174 (Befund „Seen in den Mäanderschlingen"): welche
/// Raster-Seen malt `terrain.gdshader` innerhalb und außerhalb des
/// Mäandergürtels, wie tief sind sie (in Bankfull-Tiefen) und woher kommen
/// sie? Tabellen: `docs/zielbild-measurements.md`
/// § Geister-Seen im Mäandergürtel.
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         -Xswiftc -swift-version -Xswiftc 5 --filter testBeltLakesDiagnostic
///
/// `RS_SEEDS` (Standard 1337,42), `RS_YEARS` (Standard 2300,20000),
/// `RS_NO_BELT=1` fährt dieselbe Produktion ohne Gürtel (`meanderBelt = false`),
/// `RS_DUMP=<Ordner>` schreibt je Stützstelle eine Karte als BMP.
final class BeltLakeTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testBeltLakesDiagnostic() throws {
        try skipUnlessMeasuring()
        let seeds = (env["RS_SEEDS"] ?? "1337,42").split(separator: ",").compactMap { UInt32($0) }
        let stages = (env["RS_YEARS"] ?? "2300,20000").split(separator: ",").compactMap { Double($0) }
        var cfg = SimConfig.production
        if env["RS_NO_BELT"] == "1" { cfg.meanderBelt = false }
        for seed in seeds {
            let t = Terrain(config: cfg, seed: seed, settleYears: SimConfig.productionSettleYears)
            for stage in stages {
                while t.years < stage - 1e-6 { t.step(dtYears: min(100, stage - t.years)) }
                print("\n=== Seed \(seed), Jahr \(Int(t.years)), Gürtel \(cfg.meanderBelt) ===")
                Self.report(t)
                if let dir = env["RS_DUMP"] { Self.dumpMap(t, to: "\(dir)/belt_\(seed)_\(Int(t.years))_\(cfg.meanderBelt).bmp") }
            }
        }
    }

    /// Eine gemalte See-Komponente (4er-Nachbarschaft der Pixel-Kontur auf
    /// Zellebene: Gate ≥ `lakeGateLo` und Wassersäule über `pondContourLo`).
    struct Lake {
        var cells = 0, rawWet = 0, rawWetHf = 0, lag = 0, inBelt = 0, bar = 0, channel = 0, oxbow = 0
        var sumPond = 0.0, maxPond = 0.0, sumHf = 0.0, maxHf = 0.0
        /// Zellen, deren Tiefen-Rampe im Shader unter 0,5 liegt (halbdurchsichtig).
        var thin = 0
        var sumI = 0, sumJ = 0
        var depthRef = 0.0
    }

    static func report(_ t: Terrain) {
        let n = t.cfg.n, cnt = n * n, sea = t.cfg.sea
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let field = WaterFieldRenderer()
        let water = field.bytes(t, blend: 1, geometryMode: true,
                                bandChannelFlags: render.riverRibbonMesh.bandChannelFlags,
                                bandCoverage: render.riverRibbonMesh.bandCoverage)
        // Gürtel-Maske: Scheibe um jeden wandernden Knoten (Kanal + Bank-Streifen
        // + 1 Breite Rand) und jeder Altarm-Knoten; Kanal-Maske: halbe Breite.
        var belt = [Bool](repeating: false, count: cnt)
        var chan = [Bool](repeating: false, count: cnt)
        var ox = [Bool](repeating: false, count: cnt)
        var depthAt = [Double](repeating: 0, count: cnt)
        func disk(_ x: Double, _ z: Double, _ r: Double, _ body: (Int) -> Void) {
            let ri = Int(r.rounded(.up))
            let ci = Int(x.rounded()), cj = Int(z.rounded())
            for dj in -ri...ri { for di in -ri...ri where Double(di * di + dj * dj) <= r * r {
                let i = ci + di, j = cj + dj
                if i >= 0, i < n, j >= 0, j < n { body(j * n + i) }
            } }
        }
        var oxbowWidth = 4.0
        for ch in t.meander.channels where MeanderState.migrates(ch, t.cfg) {
            for (idx, nd) in ch.nodes.enumerated() where idx < ch.discharge.count {
                let b = MeanderState.beltWidthCells(discharge: ch.discharge[idx], config: t.cfg)
                oxbowWidth = max(oxbowWidth, b)
                let d = t.cfg.meanderBeltDepthPerWidth * t.cfg.cellSize * b
                disk(nd.x, nd.z, 0.5 * b + (t.cfg.meanderBarWidths + 1) * b) { k in
                    belt[k] = true
                    if depthAt[k] < d { depthAt[k] = d }
                }
                disk(nd.x, nd.z, 0.5 * b) { chan[$0] = true }
            }
        }
        for loop in t.meander.oxbows { for nd in loop { disk(nd.x, nd.z, 0.5 * oxbowWidth) { ox[$0] = true; belt[$0] = true } } }
        for k in 0..<cnt where t.barAge[k] >= 0 { belt[k] = true }
        let gateLo = WaterRender.lakeGateLo
        var painted = [Bool](repeating: false, count: cnt)
        for k in 0..<cnt where t.h[k] > sea && t.waterLevel[k] > sea {
            let pond = t.waterLevel[k] - t.h[k]
            if pond > WaterRender.pondContourLo && Double(water[k * 4 + 1]) / 255 >= gateLo { painted[k] = true }
        }
        var seen = [Bool](repeating: false, count: cnt)
        var lakes: [Lake] = []
        let medianDepth = t.cfg.meanderBeltDepthPerWidth * t.cfg.cellSize * 6.4
        for s in 0..<cnt where painted[s] && !seen[s] {
            var L = Lake(); var stack = [s]; seen[s] = true
            while let k = stack.popLast() {
                let pond = t.waterLevel[k] - t.h[k], ph = max(0, t.hf[k] - t.h[k])
                L.cells += 1; L.sumPond += pond; L.maxPond = max(L.maxPond, pond)
                L.sumHf += ph; L.maxHf = max(L.maxHf, ph)
                if pond > WaterRender.lakeRawWetDepth { L.rawWet += 1 }
                if ph > WaterRender.lakeRawWetDepth { L.rawWetHf += 1 }
                if t.waterLevel[k] - t.hf[k] > 0.01 { L.lag += 1 }
                if belt[k] { L.inBelt += 1 }
                if t.barAge[k] >= 0 { L.bar += 1 }
                if chan[k] { L.channel += 1 }
                if ox[k] { L.oxbow += 1 }
                L.depthRef = max(L.depthRef, depthAt[k])
                if (pond - WaterRender.lakeDepthLo) / WaterRender.lakeDepthSpan < 0.5 { L.thin += 1 }
                L.sumI += k % n; L.sumJ += k / n
                let i = k % n, j = k / n
                for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && painted[nb] && !seen[nb] { seen[nb] = true; stack.append(nb) }
            }
            lakes.append(L)
        }
        let inside = lakes.filter { 2 * $0.inBelt >= $0.cells }
        let outside = lakes.filter { 2 * $0.inBelt < $0.cells }
        func sum(_ a: [Lake]) -> String {
            let c = a.reduce(0) { $0 + $1.cells }, thin = a.reduce(0) { $0 + $1.thin }
            let lag = a.reduce(0) { $0 + $1.lag }, rw = a.reduce(0) { $0 + $1.rawWet }, rwh = a.reduce(0) { $0 + $1.rawWetHf }
            return "\(a.count) Seen / \(c) Zellen, halbdurchsichtig (Tiefen-Rampe < 0,5) \(thin) Zellen, "
                + "Spiegel > hf + 0,01: \(lag) Zellen, rawWet über Spiegel / über hf: \(rw) / \(rwh)"
        }
        print("gemalte Seen im Gürtel:     \(sum(inside))")
        print("gemalte Seen außerhalb:     \(sum(outside))")
        print(String(format: "Bankfull-Tiefe D (b = 6,4 Zellen) = %.5f; Seen-Tabelle: Tiefen in D des nächsten Gürtel-Laufs", medianDepth))
        print("| Zellen | rawWet | rawWet(hf) | Spiegel>hf+0,01 | Gürtel | Bank | Kanal | Altarm | Spiegel max / Mittel (D) | hf max / Mittel (D) | halbdurchs. | Spiegel max roh | D | Welt x,z |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | --- |")
        for L in lakes.sorted(by: { $0.cells > $1.cells }).prefix(14) where L.cells >= 30 {
            let d = L.depthRef > 0 ? L.depthRef : medianDepth
            let ws = t.cfg.world
            let x = (Double(L.sumI) / Double(L.cells) + 0.5) / Double(n) * ws - 0.5 * ws
            let z = (Double(L.sumJ) / Double(L.cells) + 0.5) / Double(n) * ws - 0.5 * ws
            print(String(format: "| %d | %d | %d | %d | %d | %d | %d | %d | %.1f / %.1f | %.1f / %.1f | %d | %.4f | %.5f | %.1f,%.1f |",
                         L.cells, L.rawWet, L.rawWetHf, L.lag, L.inBelt, L.bar, L.channel, L.oxbow,
                         L.maxPond / d, L.sumPond / Double(L.cells) / d,
                         L.maxHf / d, L.sumHf / Double(L.cells) / d, L.thin, L.maxPond, d, x, z))
        }
    }

    /// Karte als BMP (Hangschattierung, gemalte Seen blau, Spiegel über hf
    /// magenta, Gürtel-Läufe rot, Altarme gelb, Bänke sandfarben).
    static func dumpMap(_ t: Terrain, to path: String) {
        let n = t.cfg.n, sea = t.cfg.sea
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let water = WaterFieldRenderer().bytes(t, blend: 1, geometryMode: true,
                                bandChannelFlags: render.riverRibbonMesh.bandChannelFlags,
                                bandCoverage: render.riverRibbonMesh.bandCoverage)
        var px = [UInt8](repeating: 0, count: n * n * 3)
        func put(_ k: Int, _ r: Double, _ g: Double, _ b: Double) {
            px[k * 3] = UInt8(max(0, min(255, b * 255))); px[k * 3 + 1] = UInt8(max(0, min(255, g * 255)))
            px[k * 3 + 2] = UInt8(max(0, min(255, r * 255)))
        }
        for j in 0..<n { for i in 0..<n {
            let k = j * n + i
            if t.h[k] <= sea { put(k, 0.05, 0.1, 0.25); continue }
            let dx = t.h[min(n - 1, i + 1) + j * n] - t.h[max(0, i - 1) + j * n]
            let dz = t.h[min(n - 1, j + 1) * n + i] - t.h[max(0, j - 1) * n + i]
            let shade = max(0.15, min(1, 0.6 - 40 * (dx + dz)))
            var r = 0.55 * shade, g = 0.6 * shade, b = 0.45 * shade
            if t.barAge[k] >= 0 { r = 0.8 * shade; g = 0.72 * shade; b = 0.5 * shade }
            let pond = t.waterLevel[k] - t.h[k]
            let gate = WaterRender.lakeMask(channel: Double(water[k * 4 + 1]) / 255, pond: pond)
            if gate > 0 {
                let d = min(1, max(0, (pond - WaterRender.lakeDepthLo) / WaterRender.lakeDepthSpan))
                r = r * (1 - gate) + gate * (0.3 - 0.25 * d); g = g * (1 - gate) + gate * (0.55 - 0.4 * d)
                b = b * (1 - gate) + gate * (0.9 - 0.3 * d)
            }
            if t.waterLevel[k] - t.hf[k] > 0.01 && pond > WaterRender.pondContourLo { r = 0.9; g = 0.2; b = 0.9 }
            put(k, r, g, b)
        } }
        for ch in t.meander.channels where MeanderState.migrates(ch, t.cfg) {
            for nd in ch.nodes { let i = Int(nd.x.rounded()), j = Int(nd.z.rounded())
                if i >= 0, i < n, j >= 0, j < n { put(j * n + i, 0.9, 0.1, 0.1) } }
        }
        for loop in t.meander.oxbows { for nd in loop { let i = Int(nd.x.rounded()), j = Int(nd.z.rounded())
            if i >= 0, i < n, j >= 0, j < n { put(j * n + i, 1, 0.95, 0.1) } } }
        // BMP, Zeilen von unten, 4-Byte-Ausrichtung; Zeile j = 0 oben.
        let row = (n * 3 + 3) & ~3, size = 54 + row * n
        var d = [UInt8](repeating: 0, count: size)
        func le(_ v: Int, _ at: Int, _ bytes: Int) { for b in 0..<bytes { d[at + b] = UInt8((v >> (8 * b)) & 0xff) } }
        d[0] = 0x42; d[1] = 0x4d; le(size, 2, 4); le(54, 10, 4); le(40, 14, 4); le(n, 18, 4); le(n, 22, 4)
        le(1, 26, 2); le(24, 28, 2); le(row * n, 34, 4)
        for j in 0..<n { for i in 0..<n { for c in 0..<3 { d[54 + (n - 1 - j) * row + i * 3 + c] = px[(j * n + i) * 3 + c] } } }
        FileManager.default.createFile(atPath: path, contents: Data(d))
    }

    /// Zeitreihe: wie entstehen die Geisterseen? Je 10-Jahr-Schritt die Zahl
    /// der Gürtel-Zellen, deren hf um > 0,005 steigt bzw. fällt, und über die
    /// Zellen mit Spiegel > hf + 0,01 im Gürtel: Anzahl, mittlere hf- und
    /// Spiegel-Säule. `RS_SEEDS`, `RS_FROM` (Standard 2000), `RS_TO` (2600),
    /// `RS_DT` (10), `RS_RELAX` (`meanderBeltRelaxYears`, z. B. 150 = Stand
    /// vor der Kalibrierung #183), `RS_NO_BELT=1`.
    func testBeltLakeHistoryDiagnostic() throws {
        try skipUnlessMeasuring()
        let seeds = (env["RS_SEEDS"] ?? "1337").split(separator: ",").compactMap { UInt32($0) }
        let from = env["RS_FROM"].flatMap { Double($0) } ?? 2000
        let to = env["RS_TO"].flatMap { Double($0) } ?? 2600
        let dt = env["RS_DT"].flatMap { Double($0) } ?? 10
        for seed in seeds {
            var cfg = SimConfig.production
            if let r = env["RS_RELAX"].flatMap({ Double($0) }) { cfg.meanderBeltRelaxYears = r }
            if env["RS_NO_BELT"] == "1" { cfg.meanderBelt = false }
            let t = Terrain(config: cfg, seed: seed, settleYears: SimConfig.productionSettleYears)
            while t.years < from - 1e-6 { t.step(dtYears: min(100, from - t.years)) }
            let n = t.cfg.n, cnt = n * n, sea = t.cfg.sea
            print("\n=== Seed \(seed), dt \(dt), Gürtel \(cfg.meanderBelt), Relaxation \(cfg.meanderBeltRelaxYears) J. ===")
            print("| Jahr | hf ↑ > 0,005 (Gürtel) | hf ↓ > 0,005 (Gürtel) | Geister-Zellen (Gürtel / sonst) | Säule hf / Spiegel (Geister, Gürtel) |")
            var acc = (up: 0, down: 0)
            var prev = t.hf
            while t.years < to - 1e-6 {
                t.step(dtYears: dt)
                for k in 0..<cnt where t.isChannel[k] || t.barAge[k] >= 0 {
                    let d = t.hf[k] - prev[k]
                    if d > 0.005 { acc.up += 1 } else if d < -0.005 { acc.down += 1 }
                }
                prev = t.hf
                if Int(t.years.rounded()) % 50 == 0 {
                    var gb = 0, go = 0, shf = 0.0, swl = 0.0
                    for k in 0..<cnt where t.h[k] > sea && t.waterLevel[k] > sea {
                        let pond = t.waterLevel[k] - t.h[k]
                        guard pond > WaterRender.pondContourLo, t.waterLevel[k] - t.hf[k] > 0.01 else { continue }
                        if t.isChannel[k] || t.barAge[k] >= 0 {
                            gb += 1; shf += t.hf[k] - t.h[k]; swl += pond
                        } else { go += 1 }
                    }
                    print(String(format: "| %.0f | %d | %d | %d / %d | %.4f / %.4f |", t.years, acc.up, acc.down,
                                 gb, go, gb > 0 ? shf / Double(gb) : 0, gb > 0 ? swl / Double(gb) : 0))
                    acc = (0, 0)
                }
            }
        }
    }
}
