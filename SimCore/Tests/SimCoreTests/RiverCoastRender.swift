import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Messreihe zu Issue #174, Paket C (Fluss, Delta, Küste sichtbar machen):
/// Größenverteilung der Raster-Wasserkomponenten (Tümpel-Teppich), Lage und
/// Steigung der Küstenzellen (Strand gegen Felsküste) und die Mündungen, die
/// eine Sedimentfahne bekommen. Tabellen: `docs/river-coast-render-measurements.md`.
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         --filter testRiverCoastRenderDiagnostic
///
/// `RS_SEED` beschränkt auf einen Seed. Laufzeit ~2 min (3 × 100.000 Jahre bei
/// n = 720, 1000er-Schritte).
final class RiverCoastRenderTests: XCTestCase {

    func testRiverCoastRenderDiagnostic() throws {
        try skipUnlessMeasuring()
        let filterSeed = ProcessInfo.processInfo.environment["RS_SEED"].flatMap { UInt32($0) }
        let stages: [Double] = [0, 2_000, 20_000, 100_000]
        for spec in GraphicsMatrixTests.matrixWorlds {
            if let fs = filterSeed, spec.seed != fs { continue }
            let t = Terrain(config: .production, seed: spec.seed,
                            settleYears: SimConfig.productionSettleYears)
            for stage in stages {
                while t.years < stage - 1e-5 { t.step(dtYears: min(1000, stage - t.years)) }
                t.computeFlow()
                print("\n=== Seed \(spec.seed), Jahr \(Int(stage)) ===")
                measureComponents(t)
                measureCoast(t)
                measureMouths(t)
                if stage == 20_000 { measureCost(t) }
            }
        }
    }

    // MARK: §A Wasserkomponenten

    private func measureComponents(_ t: Terrain) {
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let field = WaterFieldRenderer()
        let water = field.bytes(t, blend: 1, geometryMode: true,
                        bandChannelFlags: render.riverRibbonMesh.bandChannelFlags,
                        bandCoverage: render.riverRibbonMesh.bandCoverage)
        let bins = [0, 10, 25, 50, 100, 200, 400, 800, 1600, Int.max]
        print("§A Tümpel (stehendes Wasser, 4er-Komponenten): Anzahl / Zellen")
        var line = "| Größe |", sep = "| :--- |"
        var free = "| ohne Band, sichtbar vor #174 |"
        var hidden = "| ohne Band, unsichtbar |"
        var banded = "| mit Band |"
        let stats = field.componentStats
        for b in 0..<(bins.count - 1) {
            let lo = bins[b], hi = bins[b + 1]
            line += hi == Int.max ? " ≥ \(lo) |" : " \(lo)–\(hi - 1) |"
            sep += " ---: |"
            func cell(_ f: (WaterFieldRenderer.ComponentStat) -> Bool) -> String {
                let c = stats.filter { $0.cells >= lo && $0.cells < hi && f($0) }
                return " \(c.count) / \(c.reduce(0) { $0 + $1.cells }) |"
            }
            free += cell { !$0.banded && $0.visible }
            hidden += cell { !$0.banded && !$0.visible }
            banded += cell { $0.banded }
        }
        print(line); print(sep); print(free); print(hidden); print(banded)
        // Sichtbares Raster-Fluss-Wasser (R ≥ riverMaskLo) nach Komponenten.
        let n = t.cfg.n
        let lo = byte01(WaterRender.riverMaskLo)
        var vis = [Bool](repeating: false, count: n * n)
        for k in 0..<(n * n) where water[k * 4] >= lo { vis[k] = true }
        var seen = [Bool](repeating: false, count: n * n)
        var sizes: [Int] = []
        let cover = render.riverRibbonMesh.bandCoverage
        var nearBand = 0, smallFragments = 0
        for s0 in 0..<(n * n) where vis[s0] && !seen[s0] {
            var stack = [s0]; seen[s0] = true; var c = 0
            var near = false
            while let k = stack.popLast() {
                c += 1
                let i = k % n, j = k / n
                for dj in -2...2 { for di in -2...2 {
                    let ii = i + di, jj = j + dj
                    if ii >= 0, ii < n, jj >= 0, jj < n, cover.count == n * n,
                       cover[jj * n + ii] > WaterRender.protectBandThreshold { near = true }
                } }
                for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && vis[nb] && !seen[nb] { seen[nb] = true; stack.append(nb) }
            }
            sizes.append(c)
            if c < 50 { smallFragments += 1; if near { nearBand += 1 } }
        }
        print("Fluss-Fragmente < 50 Zellen: \(smallFragments), davon ≤ 2 Zellen an einem Band: \(nearBand)")
        var row = "| Fluss-Raster sichtbar |"
        for b in 0..<(bins.count - 1) {
            let c = sizes.filter { $0 >= bins[b] && $0 < bins[b + 1] }
            row += " \(c.count) / \(c.reduce(0, +)) |"
        }
        print(row)
        let lakeVis = (0..<(n * n)).filter { water[$0 * 4 + 1] >= byte01(WaterRender.lakeGateHi) }.count
        print("See-Gate voll (G ≥ lakeGateHi): \(lakeVis) Zellen, Bänder: \(render.riverRibbonMesh.stripStarts.count)")
        print("Rest-Flecken am Band zurückgenommen: \(field.remnantStats.count) / \(field.remnantStats.reduce(0, +)) Zellen")
        let meadow = field.wetMeadow.filter { $0 }.count
        print("nasse Wiese bei wetMeadowMaxCells = \(WaterRender.wetMeadowMaxCells): \(meadow) Zellen")
    }

    // MARK: §B Küste

    private func measureCoast(_ t: Terrain) {
        let n = t.cfg.n, sea = t.cfg.sea
        let dist = CoastMaterial.seaDistance(t)
        var slopes: [Double] = [], heights: [Double] = [], seds: [Double] = []
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                guard t.h[k] > sea, dist[k] <= 2 else { continue }
                slopes.append(Terrain.macroSlope(t.h, k, n))
                heights.append(t.h[k] - sea)
                seds.append(t.sed[k])
            }
        }
        func pct(_ a: [Double]) -> String {
            let s = a.sorted()
            guard !s.isEmpty else { return "—" }
            return [0.1, 0.25, 0.5, 0.75, 0.9].map {
                String(format: "%.4f", s[min(s.count - 1, Int(Double(s.count) * $0))])
            }.joined(separator: " / ")
        }
        print("§B Küstenzellen (Land, ≤ 2 Zellen vom Meer): \(slopes.count)")
        print("  macroSlope p10/25/50/75/90: \(pct(slopes))")
        print("  Höhe über NN p10/25/50/75/90: \(pct(heights))")
        print("  sed p10/25/50/75/90: \(pct(seds))")
        let buffers = TerrainColorRenderer.buffers(t)
        var sand = 0, cliff = 0, land = 0
        for k in 0..<t.cfg.count where t.h[k] > sea {
            land += 1
            if buffers.colors[k * 4 + 3] >= 128 { sand += 1 }
            if dist[k] <= 2 && buffers.surfaces[k * 4 + 1] >= 128 { cliff += 1 }
        }
        print("  Sand ≥ 0,5: \(sand) Zellen (\(String(format: "%.2f", 100 * Double(sand) / Double(max(land, 1)))) % Land), "
              + "Fels ≥ 0,5 an der Küste: \(cliff) Zellen")
    }

    // MARK: §C Mündungen

    private func measureMouths(_ t: Terrain) {
        let mouths = SedimentPlume.mouths(t)
        let sorted = mouths.sorted { $0.dischargeCells > $1.dischargeCells }
        print("§C Mündungen ins Meer (D8): \(mouths.count), davon ≥ 1000 Zellen: "
              + "\(mouths.filter { $0.dischargeCells >= 1000 }.count), ≥ 5000: "
              + "\(mouths.filter { $0.dischargeCells >= 5000 }.count), ≥ 20000: "
              + "\(mouths.filter { $0.dischargeCells >= 20000 }.count)")
        for m in sorted.prefix(8) {
            print(String(format: "  q = %8.0f Zellen, Relief = %.3f, Stärke = %.3f",
                         m.dischargeCells, m.relief, SedimentPlume.strength(m)))
        }
    }

    // MARK: §D Kosten der neuen CPU-Pässe

    /// Median über 15 Läufe je Pass (ms). Nur die Zusatzkosten von #174 C;
    /// `TerrainColorRenderer.buffers` enthält `seaDistance` bereits.
    private func measureCost(_ t: Terrain) {
        func median(_ body: () -> Void) -> Double {
            var times: [Double] = []
            for _ in 0..<15 {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return times.sorted()[times.count / 2]
        }
        let field = WaterFieldRenderer()
        _ = field.bytes(t, blend: 1, geometryMode: true, bandChannelFlags: [], bandCoverage: [])
        let buffers = TerrainColorRenderer.buffers(t)
        let mask = field.wetMeadow
        print(String(format: "§D seaDistance %.2f ms, TerrainColorRenderer.buffers %.2f ms, "
                     + "SedimentPlume.field %.2f ms, WetMeadow.apply %.2f ms, WaterFieldRenderer.bytes %.2f ms",
                     median { _ = CoastMaterial.seaDistance(t) },
                     median { _ = TerrainColorRenderer.buffers(t) },
                     median { _ = SedimentPlume.field(t) },
                     median { _ = WetMeadow.apply(buffers, mask: mask) },
                     median { _ = field.bytes(t, blend: 1, geometryMode: true,
                                              bandChannelFlags: [], bandCoverage: []) }))
    }
}
