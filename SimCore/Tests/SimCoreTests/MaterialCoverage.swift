import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Materialverteilung über die Matrix-Welten (Issue #174, Paket D).
///
/// Misst je Welt und Stadium die Standortwerte, an denen `MaterialRender`
/// kalibriert ist (Weltsteigung, Konvexität, Schnee- und Eisdeckung), und die
/// Flächenanteile der Materialien, die `TerrainColorRenderer` daraus macht —
/// vorher (Stand vor #174 D, `LegacyTerrainColor`) und nachher —, dazu den
/// Waldanteil (#168: höchstens ~22 % des Landes) und die Laufzeit des
/// Material-Passes als interleavtes A/B (alt, neu, alt, neu …; Median).
/// Tabelle: `docs/graphics-quality.md` § Material, Schnee, Wolken (#174 D).
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         --filter testMaterialCoverageDiagnostic
///
/// `RS_SEED` beschränkt auf einen Seed, `RS_YEARS` (Komma-Liste) die Stadien.
final class MaterialCoverageTests: XCTestCase {

    func testMaterialCoverageDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let filterSeed = env["RS_SEED"].flatMap { UInt32($0) }
        let stages = env["RS_YEARS"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? [2_000, 20_000, 100_000]

        print("\n=== MATERIAL (Issue #174 D) ===")
        for spec in GraphicsMatrixTests.matrixWorlds {
            if let fs = filterSeed, spec.seed != fs { continue }
            let t = Terrain(config: .production, seed: spec.seed,
                            settleYears: SimConfig.productionSettleYears)
            for stage in stages {
                while t.years < stage - 1e-5 { t.step(dtYears: min(1000, stage - t.years)) }
                t.computeFlow()
                report(t, seed: spec.seed)
            }
        }
        print("=== ENDE MATERIAL ===\n")
    }

    private func report(_ t: Terrain, seed: UInt32) {
        let n = t.cfg.n
        let h = t.h
        // Ein Frame (Issue #214): Wasser, Material und Masken entstehen
        // gemeinsam — derselbe Takt wie im Spiel.
        let overlays = frameOverlays(RenderState(geometryMode: true), t)
        let surfaces = overlays.surfaces
        let covers = overlays.covers
        let protect = overlays.protectMask
        let clump = ForestCanopyMask.clumpField(n: n, world: t.cfg.world)
        let forest = ForestCanopyMask.bytes(t, surfaces: surfaces, protect: protect, clump: clump)
        let legacy = LegacyTerrainColor.buffers(t).surfaces
        let legacyForest = ForestCanopyMask.bytes(t, surfaces: legacy, protect: protect, clump: clump)

        let slopeScale = 2 * RenderContract.heightScale / (t.cfg.world / Double(n))
        var land: [Int] = []
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) where h[j * n + i] > t.cfg.sea + 0.012 { land.append(j * n + i) }
        }
        guard !land.isEmpty else { print("Seed \(seed) Jahr \(Int(t.years)): kein Land"); return }
        let slopes = land.map { Terrain.macroSlope(h, $0, n) * slopeScale }.sorted()
        let convex = land.map { TerrainColorRenderer.convexity(h, $0, n) * RenderContract.heightScale }
            .sorted()
        func q(_ a: [Double], _ p: Double) -> Double { a[min(a.count - 1, Int(Double(a.count) * p))] }
        func share(_ pred: (Int) -> Bool) -> Double {
            100 * Double(land.filter(pred).count) / Double(land.count)
        }
        let snowOn = t.snow.count == n * n, iceOn = t.ice.count == n * n
        let maxH = land.map { h[$0] }.max() ?? 0
        let b = t.heightBands
        print(String(format: "Seed %d Jahr %d: Land %d Zellen, max h %.3f (Welt-Y %.1f)",
                     seed, Int(t.years), land.count, maxH, maxH * RenderContract.heightScale))
        print(String(format: "  Bänder: vegFull %.3f rock %.3f…%.3f snow %.3f…%.3f conifer %.3f…%.3f",
                     b.vegFull, b.rockStart, b.rockFull, b.snowStart, b.snowFull,
                     b.coniferLow, b.coniferHigh))
        print(String(format: "  Weltsteigung p10 %.2f p50 %.2f p75 %.2f p90 %.2f p95 %.2f p99 %.2f",
                     q(slopes, 0.1), q(slopes, 0.5), q(slopes, 0.75), q(slopes, 0.9),
                     q(slopes, 0.95), q(slopes, 0.99)))
        print(String(format: "  Konvexität (Welt) p01 %.3f p05 %.3f p50 %.3f p95 %.3f p99 %.3f",
                     q(convex, 0.01), q(convex, 0.05), q(convex, 0.5), q(convex, 0.95),
                     q(convex, 0.99)))
        let iced = { (k: Int) in iceOn && Terrain.iceCoverage(thickness: t.ice[k], ref: t.cfg.iceCoverRef) >= 0.1 }
        let tempOn = t.temperature.count == n * n
        print(String(format: "  Schneedeckung ≥ 0,3: %.1f %%  Eisdeckung ≥ 0,1: %.1f %% (davon über 0 °C: %.1f %%)",
                     share { snowOn && Terrain.snowCoverage(swe: t.snow[$0], ref: t.cfg.snowCoverRef) >= 0.3 },
                     share(iced), share { iced($0) && tempOn && t.temperature[$0] > 0 }))
        let w = { (buf: [UInt8], k: Int, c: Int) in Double(buf[k * 4 + c]) / 255 }
        // Grund = was nach Vegetation, Fels, Kälte, Halde und Rohboden bleibt.
        let ground = { (k: Int) in
            1 - w(surfaces, k, 0) - w(surfaces, k, 1) - w(surfaces, k, 2) - w(covers, k, 0) - w(covers, k, 2)
        }
        print(String(format: "  vorher %% Land: Fels ≥ 0,5 %.1f | Vegetation ≥ 0,14 %.1f | Wald %.1f",
                     share { w(legacy, $0, 1) >= 0.5 }, share { w(legacy, $0, 0) >= 0.14 },
                     share { legacyForest[$0] >= 128 }))
        print(String(format: "  nachher %% Land: Fels ≥ 0,5 %.1f | Schutt ≥ 0,5 %.1f | Kälte ≥ 0,5 %.1f | "
                     + "blankes Eis ≥ 0,3 (an Kälte ≥ 0,5) %.1f | Rohboden ≥ 0,3 %.1f | Talboden ≥ 0,5 %.1f | "
                     + "Grund ≥ 0,5 %.1f | Vegetation ≥ 0,14 %.1f | Wald %.1f",
                     share { w(surfaces, $0, 1) >= 0.5 }, share { w(covers, $0, 0) >= 0.5 },
                     share { w(surfaces, $0, 2) >= 0.5 },
                     share { w(surfaces, $0, 2) >= 0.5 && w(covers, $0, 1) >= 0.3 },
                     share { w(covers, $0, 2) >= 0.3 }, share { w(covers, $0, 3) >= 0.5 },
                     share { ground($0) >= 0.5 }, share { w(surfaces, $0, 0) >= 0.14 },
                     share { forest[$0] >= 128 }))
        // Interleavtes A/B: alt und neu abwechselnd, je 9 Läufe, Median.
        var old: [Double] = [], new: [Double] = []
        for _ in 0..<9 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = LegacyTerrainColor.buffers(t)
            old.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = TerrainColorRenderer.buffers(t)
            new.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        old.sort(); new.sort()
        print(String(format: "  Material-Pass (n = %d): vorher Median %.2f ms (%.2f…%.2f), "
                     + "nachher Median %.2f ms (%.2f…%.2f), 9 Läufe interleaved",
                     n, old[4], old[0], old[8], new[4], new[0], new[8]))
    }
}

/// Stand von `TerrainColorRenderer.buffers` vor #174 D (Commit 55323b5), nur
/// für den Vorher-Vergleich und das Laufzeit-A/B im Messlauf oben. Nur die
/// Puffer, die es damals gab; nicht pflegen, nicht anderswo benutzen.
enum LegacyTerrainColor {
    static func buffers(_ terrain: Terrain) -> (colors: [UInt8], surfaces: [UInt8]) {
        let n = terrain.cfg.n
        let h = terrain.h
        let rain = terrain.rain, veg = terrain.veg
        let salt = terrain.saltCrust
        guard n > 0, h.count == n * n, rain.count == n * n, veg.count == n * n,
              salt.count == n * n else {
            return ([], [])
        }
        let sea = terrain.cfg.sea
        let lith = terrain.lithHardness.count == n * n ? terrain.lithHardness : [0.0]
        let lithOn = lith.count == n * n
        let snow = terrain.snow.count == n * n ? terrain.snow : [0.0]
        let snowOn = snow.count == n * n
        let snowRef = terrain.cfg.snowCoverRef
        let ice = terrain.ice.count == n * n ? terrain.ice : [0.0]
        let iceOn = ice.count == n * n
        let iceRef = terrain.cfg.iceCoverRef
        let bands = terrain.heightBands

        var colors = [UInt8](repeating: 255, count: n * n * 4)
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        veg.withUnsafeBufferPointer { vgb in
        salt.withUnsafeBufferPointer { slb in
        lith.withUnsafeBufferPointer { ltb in
        snow.withUnsafeBufferPointer { snb in
        ice.withUnsafeBufferPointer { icb in
        colors.withUnsafeMutableBufferPointer { cb in
        surfaces.withUnsafeMutableBufferPointer { sb in
        let ph = hb.baseAddress!, prain = rnb.baseAddress!, pveg = vgb.baseAddress!
        let psalt = slb.baseAddress!, plith = ltb.baseAddress!
        let psnow = snb.baseAddress!, pice = icb.baseAddress!
        let pcolor = cb.baseAddress!, psurface = sb.baseAddress!

        parallelChunks(n) { jLo, jHi in
            for j in jLo..<jHi {
                for i in 0..<n {
                    let k = j * n + i
                    let v = ph[k]
                    let hard = lithOn ? min(1, max(-1, plith[k])) : 0
                    var r = 0.0, g = 0.0, b = 0.0
                    var vegWeight = 0.0, rockWeight = 0.0, coldWeight = 0.0
                    if v <= sea + 0.012 {
                        (r, g, b) = TerrainColorRenderer.gradColor(v)
                    } else {
                        var slope = 0.0
                        if i > 1 && i < n - 2 && j > 1 && j < n - 2 {
                            slope = Terrain.macroSlope(ph, k, n)
                        }
                        let steep = clamp01(slope * 45)
                        r = 0.29 + 0.035 * steep
                        g = 0.30 + 0.035 * steep
                        b = 0.31 + 0.04 * steep
                        let habitat = Terrain.vegetationSuitability(
                            height: v, slope: slope, rain: prain[k], bands: bands)
                        let vegAmount = clamp01((0.5 + 0.5 * pveg[k]) * habitat * 1.3) * 0.78
                        r += (0.15 - r) * vegAmount
                        g += (0.32 - g) * vegAmount
                        b += (0.10 - b) * vegAmount
                        let highRock = bands.rockAmount(v)
                        if highRock > 0 {
                            r += (0.34 - r) * highRock
                            g += (0.35 - g) * highRock
                            b += (0.37 - b) * highRock
                        }
                        let snowCover = snowOn
                            ? Terrain.snowCoverage(swe: psnow[k], ref: snowRef)
                            : bands.snowAmount(v)
                        if snowCover > 0 {
                            r += (0.88 - r) * snowCover
                            g += (0.90 - g) * snowCover
                            b += (0.93 - b) * snowCover
                        }
                        let iceCover = iceOn
                            ? Terrain.iceCoverage(thickness: pice[k], ref: iceRef)
                            : 0
                        if iceCover > 0 {
                            r += (0.68 - r) * iceCover
                            g += (0.81 - g) * iceCover
                            b += (0.92 - b) * iceCover
                        }
                        let saltCover = clamp01(psalt[k]) * 0.9
                        if saltCover > 0 {
                            r += (0.78 - r) * saltCover
                            g += (0.74 - g) * saltCover
                            b += (0.64 - b) * saltCover
                        }
                        r -= hard * 0.065
                        g -= hard * 0.075
                        b -= hard * 0.09
                        coldWeight = max(snowCover, iceCover)
                        vegWeight = vegAmount * (1 - coldWeight) * (1 - saltCover)
                        let cliff = smoothstep(0.004, 0.026, slope)
                        rockWeight = max(highRock * 0.82, cliff)
                            * (1 - vegWeight) * (1 - coldWeight) * (1 - saltCover)
                    }
                    let o = k * 4
                    pcolor[o] = byte01(r)
                    pcolor[o + 1] = byte01(g)
                    pcolor[o + 2] = byte01(b)
                    pcolor[o + 3] = 255
                    psurface[o] = byte01(vegWeight)
                    psurface[o + 1] = byte01(rockWeight)
                    psurface[o + 2] = byte01(coldWeight)
                    psurface[o + 3] = byte01(hard * 0.5 + 0.5)
                }
            }
        }
        }}}}}}}}}
        return (colors, surfaces)
    }
}
