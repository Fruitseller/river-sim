import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Waldanteil des Kronendachs über die Matrix-Welten (Issue #168).
///
/// Misst, wie viel Land Wald trägt (Waldmaske ≥ 0,5), wie viel davon
/// bewachsen ist (Vegetationsgewicht `vegW` ≥ `vegetatedFloor`, R-Kanal von
/// `surfaces`) und wie viel bewachsenes Land ohne Wald als Wiese bleibt — für
/// die Produktions-Schwellen und jede Kandidaten-Zeile in `candidates`.
/// Tabelle: `docs/graphics-quality.md` § Wald und Wiese (#168).
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         -Xswiftc -swift-version -Xswiftc 5 --filter testCanopyCoverageDiagnostic
///
/// `RS_SEED` beschränkt auf einen Seed. Laufzeit ~15 min (3 × 100.000 Jahre
/// bei n = 720).
final class CanopyCoverageTests: XCTestCase {

    /// (Name, vegetationLo, vegetationHi, clumpGain); die erste Zeile ist die
    /// Produktion, die zweite der Stand vor #168.
    private let candidates: [(String, Double, Double, Double)] = [
        ("Produktion", CanopyRender.vegetationLo, CanopyRender.vegetationHi, CanopyRender.clumpGain),
        ("vor #168", 0.14, 0.32, 0.45),
        ("0,35/0,55 g0,60", 0.35, 0.55, 0.60),
        ("0,40/0,60 g0,45", 0.40, 0.60, 0.45),
        ("0,45/0,65 g0,45", 0.45, 0.65, 0.45),
        ("0,40/0,60 g0,60", 0.40, 0.60, 0.60),
        ("0,45/0,65 g0,60", 0.45, 0.65, 0.60),
    ]

    /// Ab hier zählt eine Zelle als bewachsen: die Wald-Schwelle vor #168,
    /// damit die Spalten mit der Ticket-Tabelle vergleichbar bleiben. Der
    /// Shader tönt Wiese schon ab `CanopyRender.meadowLo` (0,08) leicht grün.
    private let vegetatedFloor = 0.14

    func testCanopyCoverageDiagnostic() throws {
        try skipUnlessMeasuring()
        let filterSeed = ProcessInfo.processInfo.environment["RS_SEED"].flatMap { UInt32($0) }
        let stages: [Double] = [2_000, 20_000, 100_000]
        let vegFloor = UInt8(vegetatedFloor * 255 + 0.5)

        print("\n=== KRONENDACH: WALDANTEIL (Issue #168) ===")
        print("| Seed | Jahr | vegW ≥ 0,14 (% Land) | vegW p50 / p90 | Schwellen | Wald (% Land) | Wiese (% Land) |")
        print("| ---: | ---: | ---: | ---: | :--- | ---: | ---: |")
        for spec in GraphicsMatrixTests.matrixWorlds {
            if let fs = filterSeed, spec.seed != fs { continue }
            let t = Terrain(config: .production, seed: spec.seed,
                            settleYears: SimConfig.productionSettleYears)
            let clump = ForestCanopyMask.clumpField(n: t.cfg.n, world: t.cfg.world)
            for stage in stages {
                while t.years < stage - 1e-5 { t.step(dtYears: min(1000, stage - t.years)) }
                t.computeFlow()
                let render = RenderState(geometryMode: true)
                render.buildRiverRibbons(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
                _ = render.waterFieldBytes(t, blend: 1.0)
                let surfaces = render.terrainSurfaceBytes(t)
                let protect = render.protectMaskBytes(t)

                var land: [Int] = []
                for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea { land.append(k) }
                let vegs = land.map { surfaces[$0 * 4] }.sorted()
                guard !vegs.isEmpty else {
                    print("| \(spec.seed) | \(Int(stage)) | kein Land | | | | |")
                    continue
                }
                let vegged = vegs.filter { $0 >= vegFloor }.count
                let pct = { (c: Int) in 100 * Double(c) / Double(max(land.count, 1)) }
                let p50 = Double(vegs[vegs.count / 2]) / 255
                let p90 = Double(vegs[vegs.count * 9 / 10]) / 255

                for (name, lo, hi, gain) in candidates {
                    let forest = ForestCanopyMask.bytes(t, surfaces: surfaces, protect: protect, clump: clump,
                                                        vegetationLo: lo, vegetationHi: hi, clumpGain: gain)
                    var wooded = 0, meadow = 0
                    for k in land {
                        if forest[k] >= 128 { wooded += 1 } else if surfaces[k * 4] >= vegFloor { meadow += 1 }
                    }
                    print(String(format: "| %d | %d | %.1f | %.2f / %.2f | %@ | %.1f | %.1f |",
                                 spec.seed, Int(stage), pct(vegged), p50, p90, name,
                                 pct(wooded), pct(meadow)))
                }
            }
        }
        print("=== ENDE WALDANTEIL ===\n")
    }
}

extension CanopyCoverageTests {

    /// Messlauf (Issue #167): warum Waldflächen im Zeitraffer springen, und was
    /// das Gedächtnis der Waldmaske dagegen tut. Alte Produktionswelt, Seed
    /// 1337, ab Jahr 100.000 20 Takte zu je 100 Jahren; die Maske entsteht
    /// alle 25 Jahre wie bei 60 J/s (Overlay-Drossel 0,30 s ≈ 18 J.).
    /// „Umkippen" = die Waldmaske kreuzt zwischen zwei Takten die 0,5, in %
    /// der Landfläche je Takt. τ = 0 ist der Stand vor #167 (kein Gedächtnis);
    /// die letzte Zeile rechnet ganz ohne Schutzmaske und ohne Gedächtnis,
    /// also nur das Umkippen, das die Sim-Vegetation selbst verursacht.
    func testCanopyChurnDiagnostic() throws {
        try skipUnlessMeasuring()
        let terrain = Terrain(config: SimConfig.production, seed: 1337,
                              settleYears: SimConfig.productionSettleYears)
        while terrain.years < 100_000 { terrain.step(dtYears: 1000) }
        let render = RenderState(geometryMode: true)
        let n = terrain.cfg.n
        let clump = ForestCanopyMask.clumpField(n: n, world: terrain.cfg.world)
        let taus: [Double] = [0, 100, 200, 300, 500, 800, 1200]
        var memories = [[Float]](repeating: [], count: taus.count)
        var lastYear = terrain.years
        /// Ein Render-Takt wie `RenderState.frame(.timelapse)`, dann je τ das
        /// Gedächtnis über die verstrichenen Sim-Jahre. Die Reihenfolge steht
        /// hier von Hand statt über `forestMaskBytes`, weil der Lauf mehrere τ
        /// gegen DASSELBE Ziel vergleicht; ändert sich das Frame-Protokoll,
        /// zieht dieser Takt mit. Die Bänder folgen dem Produktionsdeckel
        /// (`rebuildRibbonsIfDue`): geprüft jeden dritten Takt (75 J.; bei
        /// 60 J/s prüft der 1-Hz-Deckel jeden vierten Overlay-Upload, ≈ 72 J.),
        /// gebaut nur ab `ribbonRebuildDelta`.
        var frames = 0
        func frame() -> [[UInt8]] {
            render.invalidate(terrain, .advanced)
            if frames % 3 == 0, render.riversMaxDelta(terrain) > RenderState.ribbonRebuildDelta {
                render.buildRiverRibbons(terrain, hscale: RenderContract.heightScale,
                                         lift: RenderContract.riverLift)
                render.markRiversBuilt(terrain)
            }
            frames += 1
            _ = render.waterFieldBytes(terrain, blend: RenderState.timelapseWaterBlend)
            let target = ForestCanopyMask.bytes(terrain, surfaces: render.terrainSurfaceBytes(terrain),
                                                protect: render.protectMaskBytes(terrain), clump: clump)
            let dt = terrain.years - lastYear
            lastYear = terrain.years
            return taus.indices.map {
                ForestCanopyMask.regrow(&memories[$0], toward: target, dtYears: dt, tau: taus[$0])
            } + [ForestCanopyMask.bytes(terrain, surfaces: render.terrainSurfaceBytes(terrain),
                                        protect: [UInt8](repeating: 0, count: n * n), clump: clump)]
        }
        // Einlauf: Gedächtnis und Wasser-EWMA auf den Zeitraffer einschwingen.
        for _ in 0..<80 { terrain.step(dtYears: 25); _ = frame() }
        var prev = frame()
        let rows = taus.map { String(format: "%7.0f", $0) } + ["ohne Schutzmaske"]
        var flips = [Int](repeating: 0, count: rows.count)
        var forest = [Int](repeating: 0, count: rows.count)
        var land = 0
        for k in 0..<n * n where terrain.h[k] > terrain.cfg.sea { land += 1 }
        let ticks = 20
        for _ in 0..<ticks {
            var cur = prev
            for _ in 0..<4 { terrain.step(dtYears: 25); cur = frame() }
            for v in rows.indices {
                for k in 0..<n * n {
                    let b = cur[v][k] >= 128
                    if (prev[v][k] >= 128) != b { flips[v] += 1 }
                    if b { forest[v] += 1 }
                }
            }
            prev = cur
        }
        print("tau (J.)  Kipp/Takt (% Land)  Wald (% Land)")
        for v in rows.indices {
            print(String(format: "%@ %12.2f %17.1f", rows[v] as NSString,
                         100 * Double(flips[v]) / Double(ticks * land),
                         100 * Double(forest[v]) / Double(ticks * land)))
        }
    }
}
