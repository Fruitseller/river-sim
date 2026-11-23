import Foundation

public struct SimConfig: Sendable, Codable, Equatable {
    public var n: Int = 720
    public var world: Double = 112.4789
    public var sea: Double = 0.15
    public var floor: Double = -0.3

    public var baseOctaves: Int = 9
    public var baseFreq: Double = 3.5
    public var rangeLandform = true
    public var baseRelief: Double = 0.78
    public var upliftFreq: Double = 2.5

    public var preErodeEnabled = true
    public var preErodeParams: ErosionFilter.Params = ErosionFilter.Params()

    public var mExp: Double = 0.5
    public var kRock: Double = 3.5e-5

    public var mfdExponent: Double = 4.0
    public var mfdUpdateInterval: Int = 1
    public var rainWeightedFlow = true
    public var kSed: Double = 1.1e-4
    public var sedCoverThresh: Double = 0.01
    public var transportCap: Double = 9.0

    public var lithologyEnabled = true
    public var lithLayerThickness: Double = 0.06
    public var lithDip: Double = 0.22
    public var lithWarp: Double = 0.05
    public var lithProvinceMix: Double = 0.35
    public var lithContrast: Double = 0.6
    public var lithDiffusionContrast: Double = 0.45
    public var lithHardBias: Double = 0.0

    public var braidingEnabled: Bool = true
    public var braidMinCells: Double = 120
    public var renderMinCells: Double = 320
    public var braidExponent: Double = 2.5
    public var braidCapacity: Double = 5.0e-6
    public var braidBarHeight: Double = 0.006
    public var braidDeltaCeiling: Double = 0.05
    public var braidDispersion: Double = 2.0

    public var hydraulicEnabled = true
    public var streamRefRate: Double = 0.0025
    public var streamMapMemoryYears: Double = 6000
    public var hydraulicPerYear = 2.0
    public var hydraulicSkipWaterSpawns = false
    public var outletIncision = true
    public var outletErode: Double = 3.0e-5
    public var hillDiffusion: Double = 0.012
    public var channelFlowMinCells: Double = 320
    public var channelFlowFullCells: Double = 3200
    public var channelDiffusionDamp: Double = 0.15
    public var channelTargetDepth: Double = 0.0146
    public var flowDepositDamp: Double = 0.15
    public var puddleFillSkipsFlowCells = false
    public var floodplainEnabled = false
    public var floodplainMinArea: Double = 500
    public var floodplainMaxElev: Double = 0.50
    public var floodplainDepth: Double = 0.016
    public var floodplainDepthK: Double = 0.020
    public var floodplainWidthK: Double = 1.8
    public var floodplainFillYears: Double = 2500

    public var breachEnabled = true
    public var breachMaxRounds = 30
    public var breachDT: Double = 6000
    public var breachTargetLakeFrac = 0.05
    public var basinFill = false
    public var puddleFillDepth = 0.06
    public var puddleFillYears = 800.0
    public var puddleLakeCoreCells = 48
    public var endorheicEvaporation = true
    public var endorheicEvapRatio: Double = 1.25
    public var endorheicAridity: Double = 0.5
    public var endorheicMinBasinCells: Int = 12
    public var endorheicResponseYears: Double = 500.0
    public var endorheicSaltYears: Double = 400.0
    public var endorheicSaltMinDepth: Double = 0.03
    public var lakeLevelResponseYears = 350.0
    public var hydraulic: HydraulicParams = {
        var h = HydraulicParams()
        h.inertia = 0.10
        return h
    }()

    public var reliefTarget: Double = 0.05
    public var reliefServoPer100y: Double = 0.0015
    public var reliefServoBand: Double = 0.07

    public var upliftDecayStartPer100y: Double = 0.0008
    public var upliftDecayFloorPer100y: Double = 0.00008
    public var upliftDecayYears: Double = 40000

    public var upliftPer100y: Double = 0.0
    public var isoHighClamp: Double = 0.90
    public var isoLowRange: Double = 0.35

    public var waveBand: Double = 0.06
    public var waveTalus: Double = 0.002
    public var waveRelax: Double = 0.5

    public var deltaTrapFraction: Double = 1.0
    public var deltaMinCells: Double = 4000
    public var deltaTopset: Double = 0.0015
    public var deltaBarDistanceWidths: Double = 2.0
    public var deltaBarRadiusWidths: Double = 0.9
    public var deltaBarElongation: Double = 2.0
    public var deltaBifurcationAngle: Double = 1.2
    public var deltaGenerations = 3
    public var deltaMinHalfWidth: Double = 1.2
    public var deltaJitter: Double = 0.3

    public var bandVegFullPercentile: Double = 0.91
    public var bandVegRampSpanFactor: Double = 1.0
    public var bandRockPercentile: Double = 0.92
    public var bandRockFullPercentile: Double = 0.995
    public var bandSnowPercentile: Double = 0.985
    public var bandSnowFullPercentile: Double = 0.9985
    public var bandConiferLowPercentile: Double = 0.15
    public var bandConiferHighPercentile: Double = 0.88
    public var bandMinRampWidth: Double = 0.004
    public var heightBandsOverride: HeightBands? = nil

    public var climateEnabled = true
    public var climateSeaLevelTemp: Double = 11.0
    public var climateLapseRate: Double = 26.0
    public var snowFreezeTemp: Double = -1.0
    public var snowRainTemp: Double = 3.0
    public var snowAccumPerYear: Double = 0.002
    public var snowTurnoverYears: Double = 500
    public var snowMeltPerKYear: Double = 0.06
    public var snowCoverRef: Double = 0.10
    public var snowBandCoverStart: Double = 0.5
    public var snowBandCoverFull: Double = 0.8

    public var meltRunoffEnabled = true
    public var meltRunoffNormalized = true
    public var meltRunoffWithholdSolid: Double = 0
    public var meltRunoffCapPerRain: Double = 1.0

    public var iceEnabled = true
    public var iceFirnPerSnowYear: Double = 1e-3
    public var iceFirnColdSpan: Double = 2.0
    public var iceFirnTemp: Double = -2.0
        public var iceAvalancheSlopeLo: Double = 1.2
    public var iceAvalancheSlopeHi: Double = 1.9
    public var iceAvalancheMaxRun: Int = 40
    public var iceAvalancheReach: Int = 1
    public var iceTurnoverYears: Double = 4000
    public var iceMeltPerKYear: Double = 0.001
    public var iceFlowK: Double = 3.0
    public var iceFlowSubCap: Double = 0.25
    public var iceFlowMoveFraction: Double = 0.5
    public var iceErodeK: Double = 1.05e-4
    public var iceErodeFluxExp: Double = 0.5
    public var iceErodeSwathRadius: Int = 4
    public var iceMoraineK: Double = 0.05
    public var iceMinThickness: Double = 0.002
    public var iceCoverRef: Double = 0.01

    public var vegTimeConstant: Double = 250

    public var vegTypeFactorForest: Double = 1.1
    public var vegTypeFactorRiparian: Double = 1.3
    public var meanderCohesion: Double = 0.5

    public var vegFloodKillDepth: Double = 0.03
    public var vegFloodKillYears: Double = 20
    public var vegDispersalRadius: Double = 2
    public var vegDispersalStrength: Double = 0.75

    public var meanderEnabled: Bool = true
    public var meanderMigration: Double = 8.0e-6
    public var meanderMaxSinuosity: Double = 3.0
    public var meanderMinCells: Double = 85
    public var meanderNodeSpacing: Double = 1.5
    public var meanderNeckDist: Double = 2.0
    public var meanderSmooth: Double = 0.12
    public var meanderSpatialCutoffIndex = false
    public var meanderFlatSlope: Double = 0.02
    public var meanderSkew: Double = 0.5
    public var meanderSkewLength: Double = 4.0
    public var meanderCarve: Double = 2.5e-4
    public var meanderBankErode: Double = 1.2e-4
    public var meanderBankWidth: Double = 1.6
    public var channelErodeDamp: Double = 0.4
    public var oxbowFillYears: Double = 5500
    public var oxbowMaxAge: Double = 25000

    public var meanderBelt = true
    public var meanderBeltLocalWeight: Double = -1.0
    public var meanderBeltUpstreamWeight: Double = 1.2
    public var meanderBeltDownstreamWeight: Double = 0.8
    public var meanderBeltKernelWidths: Double = 0.85
    public var meanderBeltRate: Double = 0.03
    public var meanderBeltNoise: Double = 0.01
    public var meanderBeltBrakeDepths: Double = 3.0
    public var meanderBeltMinCells: Double = 2000
    public var meanderBeltDepthPerWidth: Double = 0.0021
    public var meanderBeltSillCutDepths: Double = 3.0
    public var meanderBeltPoolSkew: Double = 3.0
    public var meanderBeltPoolGain: Double = 4.0
    public var meanderBeltProfileWidths: Double = 1
    public var meanderBeltRelaxYears: Double = 10
    public var meanderBarTopDepth: Double = 0.15
    public var meanderBarWidths: Double = 0.75
    public var meanderBeltSinuosityStart: Double = 3.0
    public var meanderBeltSinuosityFull: Double = 4.0
    public var meanderBeltSinuosityWidths: Double = 10
    public var meanderBeltNeckWidths: Double = 1.0
    public var meanderBeltMaxLoopWidths: Double = 150
    public var meanderChuteWidths: Double = 2.0
    public var meanderChuteLoopRatio: Double = 8.0
    public var meanderChuteMinCells: Double = 4000

    public var meanderBeltCoupling = true
    public var meanderBeltCouplingYears: Double = 1000
    public var meanderBeltSymmetricStamp = true
    public var meanderBeltCouplingSlackCells: Double = 4
    public var meanderBeltAvulsionWidths: Double = 2.0
    public var meanderBeltAvulsionDepths: Double = 2.0
    public var meanderBeltAvulsionYears: Double = 1000
    public var meanderBeltAbandonMinWidths: Double = 5

    public var disturbanceEnabled = true
    public var disturbanceFullChange: Double = 0.04
    public var disturbanceRecoveryYears: Double = 1200
    public var disturbanceSettle: Double = 0.35
    public var disturbanceReliefAmp: Double = 0.012
    public var disturbanceReliefFreq: Double = 0.02
    public var disturbanceVegSuppress: Double = 1.0
    public var disturbanceMeanderDrop: Double = 0.5

    public init() {}

    public var cellSize: Double {
        guard n > 1, world.isFinite, world > 0 else { return 0 }
        return world / Double(n - 1)
    }

    public var count: Int {
        guard n > 0 else { return 0 }
        let (prod, overflow) = n.multipliedReportingOverflow(by: n)
        return overflow ? 0 : prod
    }
}

extension SimConfig {
    public static var production: SimConfig {
        var config = SimConfig()
        config.enableProductionPerformance()
        return config
    }

    public mutating func enableProductionPerformance() {
        hydraulicSkipWaterSpawns = true
        meanderSpatialCutoffIndex = true
    }

    public static let productionSettleYears = 3000.0
}
