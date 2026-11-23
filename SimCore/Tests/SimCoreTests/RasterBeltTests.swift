import XCTest

@testable import SimCore
@testable import SimRender

final class RasterBeltTests: XCTestCase {

    nonisolated(unsafe) private static let world: (terrain: Terrain, mesh: RibbonMesh,
                                                   water: [UInt8], departure: [Double]) = {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)
        let mesh = builtRibbons(terrain).mesh
        let field = WaterFieldRenderer()
        let water = field.bytes(terrain, blend: 1, geometryMode: true,
                                               bandChannelFlags: mesh.bandChannelFlags,
                                               bandCoverage: mesh.bandCoverage, deferTail: true)
        return (terrain, mesh, water, field.waterDeparture)
    }()

    private func visible(_ water: [UInt8], _ k: Int) -> Bool {
        water[k * 4] >= byte01(WaterRender.riverMaskLo)
    }

    func testNoRasterSpeckleInBandCorridors() {
        let (terrain, _, water, _) = Self.world
        let n = terrain.cfg.n
        var seen = [Bool](repeating: false, count: n * n)
        var small: [Int] = []
        for s in 0..<(n * n) where visible(water, s) && !seen[s] {
            var stack = [s]; seen[s] = true; var cells = 0, lake = false
            while let k = stack.popLast() {
                cells += 1
                let i = k % n, j = k / n
                for (ok, nb) in [(true, k), (i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && terrain.waterLevel[nb] > terrain.cfg.sea
                    && terrain.waterLevel[nb] - terrain.h[nb] > WaterRender.lakeRawWetDepth { lake = true }
                for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && visible(water, nb) && !seen[nb] { seen[nb] = true; stack.append(nb) }
            }
            if cells < WaterRender.streamGateCells && !lake { small.append(cells) }
        }
        XCTAssertEqual(small.count, 0,
            "sichtbare Raster-Flecken unter dem Kohärenz-Gate: \(small.count) (Zellen \(small.prefix(12)))")
    }

    func testRasterLeavesBarsNextToTheirBand() {
        let (terrain, mesh, water, departure) = Self.world
        let n = terrain.cfg.n
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let reach = WaterRender.rasterBarBandReachCells
        var bandQ = [Double](repeating: 0, count: n * n)
        for (ci, ch) in terrain.meander.channels.enumerated()
        where ci < mesh.bandChannelFlags.count && mesh.bandChannelFlags[ci] {
            for (a, node) in ch.nodes.enumerated() where a < ch.discharge.count {
                let i = min(max(Int(node.x.rounded()), 0), n - 1), j = min(max(Int(node.z.rounded()), 0), n - 1)
                if mesh.bandCoverage[j * n + i] >= WaterRender.rasterBarBandCoverage {
                    bandQ[j * n + i] = max(bandQ[j * n + i], ch.discharge[a])
                }
            }
        }
        var bars = 0, offenders = 0
        for k in 0..<(n * n) where terrain.barAge[k] >= 0 {
            bars += 1
            guard visible(water, k) else { continue }
            guard departure[k] == 0 else { continue }
            let i = k % n, j = k / n
            var near = 0.0
            for jj in max(0, j - reach)...min(n - 1, j + reach) {
                for ii in max(0, i - reach)...min(n - 1, i + reach) { near = max(near, bandQ[jj * n + ii]) }
            }
            if near > 0 && near >= WaterRender.rasterBarBandDischargeRatio * terrain.areaMFD[k] / cellArea {
                offenders += 1
            }
        }
        XCTAssertGreaterThan(bars, 100, "Testwelt ohne Gürtel-Bänke — der Test prüft nichts")
        XCTAssertEqual(offenders, 0, "Raster-Fluss auf Bänken neben dem eigenen Band")
    }
}
