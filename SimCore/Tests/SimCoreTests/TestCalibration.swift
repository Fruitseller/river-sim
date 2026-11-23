import Foundation

@testable import SimCore
@testable import SimRender

let calibrationWorld: Double = 130

let calibrationRangeLandform = false

let calibrationMeanderBelt = false

let calibrationBeltCouplingYears: Double = 0

let calibrationBeltDtRate: Double = 0.02
let calibrationBeltDtKernelWidths: Double = 1.5

let calibrationBeltRenderKernelWidths: Double = 1.0
let calibrationBeltSymmetricStamp = false

let calibrationIceFirnTemp: Double = 0

let calibrationDeltaTrapFraction: Double = 0

let calibrationIceAvalancheSlopeHi: Double = 0

let calibrationMeanderBeltSillCutDepths: Double = 0

extension SimConfig {
    mutating func pinIceBeforeAvalanche() {
        iceAvalancheSlopeHi = calibrationIceAvalancheSlopeHi
        iceErodeSwathRadius = 2
        iceErodeK = 1e-4
    }
}

func renderConfig(n: Int = 96) -> SimConfig {
    var config = SimConfig()
    config.n = n
    config.world = n > 1 ? calibrationWorld : 0
    config.rangeLandform = calibrationRangeLandform
    config.iceFirnTemp = calibrationIceFirnTemp
    config.pinIceBeforeAvalanche()
    return config
}

func agedWorld(_ config: SimConfig, years: Double, seed: UInt32 = 1337) -> Terrain {
    let terrain = Terrain(config: config, seed: seed)
    while terrain.years < years {
        terrain.step(dtYears: min(1000, years - terrain.years))
    }
    terrain.computeFlow()
    return terrain
}

func frameOverlays(_ render: RenderState, _ terrain: Terrain,
                   trigger: FrameTrigger = .settled, now: Double = 0) -> RenderFrame.Overlays {
    guard let overlays = render.frame(terrain, trigger, now: now).overlays else {
        fatalError("Ein \(trigger)-Frame muss Overlays liefern (Drossel prüfen)")
    }
    return overlays
}

@discardableResult
func builtRibbons(_ terrain: Terrain,
                  hscale: Double = RenderContract.heightScale,
                  lift: Double = RenderContract.riverLift) -> RiverRibbonRenderer {
    let ribbons = RiverRibbonRenderer()
    ribbons.build(terrain, hscale: hscale, lift: lift)
    return ribbons
}
