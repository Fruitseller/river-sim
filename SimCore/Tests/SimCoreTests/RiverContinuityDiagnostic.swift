import Foundation
import XCTest
@testable import SimCore
@testable import SimRender

final class RiverContinuityDiagnostics: XCTestCase {
    func testRiverContinuityDiagnostic() throws {
        try skipUnlessMeasuring()
        print("CONT Seed | Jahr | Lücken-Zellen | Strecken | längste | Band-Zellen | Raster-Zellen | Keile vor Band | Raster quer durch Band")
        for seed: UInt32 in [1337, 42, 20] {
            let world = Terrain(config: .production, seed: seed,
                                settleYears: SimConfig.productionSettleYears)
            for target in [2600.0, 4000.0] {
                while world.years < target { world.step(dtYears: min(1000, target - world.years)) }
                world.recomputeFlowAfterEdit()
                let render = RenderState(geometryMode: true)
                render.renderGrid = world.cfg.n
                render.invalidate(world, .replaced)
                _ = render.frame(world, .settled, now: 0)
                let mesh = render.riverRibbonMesh
                let water = render.waterFieldBytes(world, blend: 1, deferTail: true)
                let m = RiverContinuity.measure(world, bandCoverage: mesh.bandCoverage, water: water)
                let wedges = RiverContinuity.endsBeforeBand(world, mesh: mesh)
                print("CONT \(seed) | \(Int(world.years)) | \(m.gapCells) | \(m.gapStretches) | \(m.longestGap) | \(m.bandCells) | \(m.rasterCells) | \(wedges) | \(m.rasterCrossings)")
            }
        }
    }
}

final class RiverContinuityCostDiagnostics: XCTestCase {
    func testRiverContinuityCostDiagnostic() throws {
        try skipUnlessMeasuring()
        let world = Terrain(config: .production, seed: 1337, settleYears: SimConfig.productionSettleYears)
        while world.years < 4000 { world.step(dtYears: 1000) }
        world.recomputeFlowAfterEdit()
        let render = RenderState(geometryMode: true)
        render.renderGrid = world.cfg.n
        render.invalidate(world, .replaced)
        _ = render.frame(world, .settled, now: 0)
        var ribbon: [Double] = [], water: [Double] = []
        for _ in 0..<25 {
            var t0 = DispatchTime.now().uptimeNanoseconds
            render.buildRiverRibbons(world, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
            ribbon.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            t0 = DispatchTime.now().uptimeNanoseconds
            _ = render.waterFieldBytes(world, blend: 1)
            water.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }

        print(String(format: "COST Band-Bau %.2f ms, Wasserfeld %.2f ms (Median aus 25)", median(ribbon), median(water)))
    }
}
