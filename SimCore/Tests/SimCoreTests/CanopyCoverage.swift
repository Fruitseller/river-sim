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
