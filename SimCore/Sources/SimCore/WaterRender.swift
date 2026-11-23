import Foundation

public enum WaterRender {

    public static let componentFadeLoCells = 10.0
    public static let componentFadeHiCells = 50.0

    @inline(__always)
    public static func componentFade(cells: Int) -> Double {
        min(1, max(0, (Double(cells) - componentFadeLoCells)
                      / (componentFadeHiCells - componentFadeLoCells)))
    }

    public static let lakeGateLo = 0.04
    public static let lakeGateHi = 0.35
    public static let riverMaskLo = 0.16
    public static let riverMaskHi = 0.45
    public static let riverDepthLo = 0.05
    public static let riverDepthHi = 0.6

    public static let shoreLo = 0.09
    public static let shoreHi = 0.16

    public static let ribbonHaloIntensity = 0.14

    public static let protectRiverThreshold = riverMaskLo
    public static let protectLakeThreshold = lakeGateLo
    public static let protectBandThreshold = 0.01
    public static let protectSeamCells = 2

    public static let streamGateFade = riverMaskHi

    @inline(__always)
    public static func streamGate(componentFade fade: Double) -> Double {
        fade >= streamGateFade ? 1 : 0
    }

    public static var streamGateCells: Int {
        var cells = Int(componentFadeLoCells)
        while Double(cells) <= componentFadeHiCells,
              streamGate(componentFade: componentFade(cells: cells)) == 0 {
            cells += 1
        }
        return cells
    }

    @inline(__always)
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    public static func riverMask(stream: Double) -> Double {
        smoothstep(riverMaskLo, riverMaskHi, stream)
    }

    public static func lakeGate(channel: Double) -> Double {
        smoothstep(lakeGateLo, lakeGateHi, channel)
    }

    public static func lakeMask(channel: Double, pond: Double) -> Double {
        smoothstep(pondContourLo, pondContourHi, pond) * lakeGate(channel: channel)
    }

    public static func shore(stream: Double, lakeGateChannel: Double, pond: Double) -> Double {
        let s = stream.isFinite ? stream : 0
        let l = lakeGateChannel.isFinite ? lakeGateChannel : 0
        let wet = max(riverMask(stream: s), lakeMask(channel: l, pond: pond))
        let dry = 1 - smoothstep(pondContourLo, pondContourHi, pond)
        return smoothstep(shoreLo, shoreHi, max(s, l)) * (1 - wet) * dry
    }

    public static let pondContourLo = 0.003
    public static let pondContourHi = 0.02

    public static let geometryLiftLo = 0.015
    public static let geometryLiftHi = 0.05

    public static let lakeDepthLo = 0.004
    public static let lakeDepthSpan = 0.05

    public static let ribbonKindRiver = 0.0
    public static let ribbonKindDelta = 0.5
    public static let ribbonKindOxbow = 1.0

    public static let mouthOverlapCells = 2.0
    public static let mouthSeaCells = 2 * mouthOverlapCells + 1
    public static let mouthJunctionSmoothSamples = 10
    public static let mouthJunctionMaxSmoothPasses = 24
    public static let mouthRayLandCells = 3

    public static let lakeRawWetDepth = 0.03
    public static let lagoonMaxRise = 0.003

    public static let deltaFrontDepth = lakeRawWetDepth

    public static let deltaMinArmCells = 3
    public static let deltaMaxArmCells = 10
    public static let deltaArmSpread = 0.44
    public static let deltaFanSpacingCells = 3.0
    public static let ribbonOcclusionLo = 0.3
    public static let ribbonOcclusionHi = 0.9

    public static let ribbonLakeSurfaceLift = 0.04
    public static let ribbonSeaSurfaceSink = -0.06

    public static let ribbonStillLo = 0.75
    public static let ribbonStillHi = 1.0
    public static let ribbonDeltaLo = 0.25
    public static let ribbonDeltaHi = 0.5

    public static func ribbonStillWeight(kind: Double) -> Double {
        smoothstep(ribbonStillLo, ribbonStillHi, kind)
    }

    public static func ribbonDeltaWeight(kind: Double) -> Double {
        (1 - ribbonStillWeight(kind: kind)) * smoothstep(ribbonDeltaLo, ribbonDeltaHi, kind)
    }
    public static let deltaArmOpacity = 0.35

    public static let ribbonHalfWidthAtReference = 0.8
    public static let ribbonHalfWidthFloorCells = 0.12
    public static let ribbonHalfWidthCapCells = 3.2

    public static let ribbonMaxCrossSlope = 0.4

    @inline(__always)
    public static func ribbonHalfWidthCells(dischargeCells: Double,
                                            referenceCells: Double) -> Double {
        guard referenceCells > 0 else { return ribbonHalfWidthFloorCells }
        let w = ribbonHalfWidthAtReference
            * (max(0, dischargeCells) / referenceCells).squareRoot()
        return min(ribbonHalfWidthCapCells, max(ribbonHalfWidthFloorCells, w))
    }

    public static let ribbonHaloMarginCells = 1.0

    public static let oxbowHalfWidthCells = 1.0

    public static let deltaArmMinHalfWidthCells = 1.5
    public static let deltaArmWidthAtMouth = 1.2
    public static let deltaArmWidthTaper = 0.6
    public static let deltaArmRankFactor = 0.35

    public static let ribbonSourceTaperCells = 4.0
    public static let ribbonTailTaperCells = 2.0
    public static let ribbonLandTaperHalfWidths = 3.0
    public static let ribbonMaxHalfWidthSlope = 1.0
    public static let ribbonMinimumAlpha = 0.02
    public static let ribbonMaxAlphaStep = 0.35
    public static let ribbonHandoverSmoothSamples = 2
    public static let ribbonRankDivisor = 6.0
    public static let ribbonMinimumRank = 0.48

    public static let ribbonUphillFadeStart = 0.004
    public static let ribbonUphillFadeEnd = 0.008

    @inline(__always)
    public static func ribbonUphillFade(rise: Double) -> Double {
        1 - smoothstep(ribbonUphillFadeStart, ribbonUphillFadeEnd, rise)
    }

    public static let cascadeSlopeLo = 0.02
    public static let cascadeSlopeSpan = 0.03

    @inline(__always)
    public static func cascadeWeight(slope: Double) -> Double {
        min(1, max(0, (abs(slope) - cascadeSlopeLo) / cascadeSlopeSpan))
    }

    public static let rasterBarBandReachCells = 16
    public static let rasterBarBandCoverage = 0.3
    public static let rasterBarBandDischargeRatio = 0.5

    public static let departureMaxCells = 2 * rasterBarBandReachCells
    public static let departureEdgeCoverage = 0.5

    public static let ribbonJoinSearchCells = 8
    public static let ribbonJoinCoverage = 0.5

    public static let rasterWallSlopeLo = (cascadeSlopeLo + cascadeSlopeSpan) * RenderContract.heightScale
    public static let rasterWallSlopeHi = 1.9

    public static let ribbonFadeOpacityCap = 0.99

    @inline(__always)
    public static func ribbonFadeOpacity(alpha: Double, share: Double) -> Double {
        if share >= 1 { return alpha }
        let a = min(max(alpha, 0), ribbonFadeOpacityCap)
        return 1 - pow(1 - a, max(share, 0))
    }

    public static let ribbonSupportLo = 0.35
    public static let ribbonSupportSpan = 0.3

    public static let ribbonTrustLoReferences = 3.0
    public static let ribbonTrustHiReferences = 10.0

    @inline(__always)
    public static func ribbonTrust(dischargeCells: Double, referenceCells: Double) -> Double {
        guard referenceCells > 0, dischargeCells.isFinite else { return 0 }
        return smoothstep(ribbonTrustLoReferences * referenceCells,
                          ribbonTrustHiReferences * referenceCells, dischargeCells)
    }

    public static let ribbonTrustBandClearanceCells = 1

    public static let ribbonGrowYears = 180.0
    public static let ribbonGrowMinWidth = 0.2
    public static let ribbonGrowVisibleCoverage = 0.05
    public static func ribbonGrowWidth(_ growth: Double) -> Double {
        growth >= 1 ? 1 : ribbonGrowMinWidth + (1 - ribbonGrowMinWidth) * max(0, growth)
    }
    public static func ribbonGrowth(ageYears age: Double) -> Double {
        guard age.isFinite else { return age > 0 ? 1 : 0 }
        return smoothstep(0, ribbonGrowYears, age)
    }
    public static let ribbonGhostYears = 150.0
    public static func ribbonGhostFade(ageYears age: Double) -> Double {
        guard age.isFinite else { return age > 0 ? 0 : 1 }
        return 1 - smoothstep(0, ribbonGhostYears, age)
    }

    public static let oxbowMinimumNodes = 20
    public static let oxbowMaximumTrimmedNodes = 3
    public static let oxbowEndFadeSteps = 3.0
    public static let oxbowMaximumOpacity = 0.7

    public static let oxbowVisibleYears = 6000.0

    public static let ribbonCurvatureWidthFactor = 0.5

    public static let mouthSearchCells = 16
    public static let mouthAlphaHoldCells = 5.0

    public static let streamPondTolerance = 0.01

    public static let trackMaskLo = 0.18
    public static let trackMaskSpan = 0.24
    public static let trackWeightFloor = 0.35
    public static let trackWeightSpan = 0.65

    public static let streamIntensityBase = 0.4
    public static let streamIntensityLogDivisor = 4.0

    @inline(__always)
    public static func trackMask(streamMap: Double) -> Double {
        min(1, max(0, (streamMap - trackMaskLo) / trackMaskSpan))
    }

    @inline(__always)
    public static func trackWeight(mask: Double) -> Double {
        trackWeightFloor + trackWeightSpan * min(1, max(0, mask))
    }

    @inline(__always)
    public static func streamIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        guard creekCells > 0 else { return streamIntensityBase }
        return min(1, streamIntensityBase
                      + log(max(0, dischargeCells) / creekCells + 1) / streamIntensityLogDivisor)
    }

    public static let continuityDecayPerCell = 0.015
    public static let continuityFloor = 0.3

    public static let flowDetailFloorCells = 3.0
    public static let flowDetailGainLo = 0.3
    public static let flowDetailGainHi = 1.8

    @inline(__always)
    public static func flowDetailIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        guard dischargeCells > flowDetailFloorCells else { return 0 }
        let ceiling = max(flowDetailFloorCells * 2, creekCells)
        return min(1, max(0, log(dischargeCells / flowDetailFloorCells)
                             / log(ceiling / flowDetailFloorCells)))
    }

    public static let widenThresholds = [0.55, 0.8]
    public static let widenFalloff = 0.09
    public static let widenBarTolerance = 0.004

    public static let widenRadiusAtFirstThreshold = 1.0
    public static let widenRadiusAtSecondThreshold = 1.1
    public static let widenRadiusFull = 1.35
    public static let widenShoulderCells = 1.0
    public static let widenWidthJitter = 0.4
    public static let widenWavelengthCells = 12.0
    public static let widenWanderRadii = 2.4
    public static let widenCrowdCells = 3
    public static let widenCrowdLo = 0.2
    public static let widenCrowdHi = 0.5
    public static let widenCrowdMinimum = 0.55

    @inline(__always)
    public static func widenCrowdFactor(share: Double) -> Double {
        let u = min(1, max(0, (share - widenCrowdLo) / (widenCrowdHi - widenCrowdLo)))
        return 1 - (1 - widenCrowdMinimum) * u
    }

    public static let widenHeadTaperCells = 6

    @inline(__always)
    public static func widenHeadTaper(upstreamCells: Int) -> Double {
        let u = min(1, Double(upstreamCells) / Double(max(1, widenHeadTaperCells)))
        return 0.35 + 0.65 * u
    }

    @inline(__always)
    public static func widenRadius(intensity s: Double) -> Double {
        let t0 = widenThresholds[0], t1 = widenThresholds[1]
        if !(s > t0) { return 0 }
        if s <= t1 {
            return widenRadiusAtFirstThreshold
                + (widenRadiusAtSecondThreshold - widenRadiusAtFirstThreshold) * (s - t0) / (t1 - t0)
        }
        let u = min(1, (s - t1) / (1 - t1))
        return widenRadiusAtSecondThreshold + (widenRadiusFull - widenRadiusAtSecondThreshold) * u
    }

    public static let corridorTrackLo = 0.1
    public static let corridorTrackSpan = 0.2
    public static let corridorWeightFloor = 0.3
    public static let corridorWeightSpan = 0.7

    @inline(__always)
    public static func corridorMask(streamMap: Double) -> Double {
        min(1, max(0, (streamMap - corridorTrackLo) / corridorTrackSpan))
    }

    @inline(__always)
    public static func corridorWeight(mask: Double) -> Double {
        corridorWeightFloor + corridorWeightSpan * min(1, max(0, mask))
    }

    public static let stampHalfWidthBase = 0.3
    public static let stampHalfWidthLogDivisor = 2.6
    public static let stampHalfWidthCapCells = 1.0
    public static let stampIntensityBase = 0.6
    public static let stampIntensityLogDivisor = 4.0

    @inline(__always)
    public static func stampHalfWidthCells(dischargeCells: Double, creekCells: Double) -> Double {
        guard creekCells > 0, !dischargeCells.isNaN else { return stampHalfWidthBase }
        return min(stampHalfWidthCapCells,
                   max(0.0,
                       stampHalfWidthBase
                       + log(max(1.0, dischargeCells) / creekCells + 1) / stampHalfWidthLogDivisor))
    }

    @inline(__always)
    public static func stampIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        guard creekCells > 0, !dischargeCells.isNaN else { return stampIntensityBase }
        return min(1.0, max(0.0, stampIntensityBase
                                 + log(max(1.0, dischargeCells) / creekCells + 1) / stampIntensityLogDivisor))
    }

    public static let waterShallowColor = (r: 0.04, g: 0.16, b: 0.14)
    public static let waterDeepColor = (r: 0.006, g: 0.050, b: 0.062)
    public static let fresnelExponent = 5.0
    public static let waterOpacityShallow = 0.55
    public static let waterOpacityDeep = 0.95
    public static let waterRoughness = 0.08
    public static let waterSpecular = 0.5
    public static let flowShimmerColor = (r: 0.012, g: 0.018, b: 0.025)
    public static let deltaPlumeColor = (r: 0.34, g: 0.38, b: 0.33)
    public static let oxbowWaterColor = (r: 0.16, g: 0.28, b: 0.24)

    public static let oceanDepthSpan = 0.06
    public static let oceanShallowColor = (r: 0.055, g: 0.39, b: 0.33)
    public static let oceanMidColor = (r: 0.012, g: 0.123, b: 0.156)
    public static let oceanDeepColor = (r: 0.005, g: 0.038, b: 0.069)
    public static let oceanMidDepth = 0.31
    public static let oceanShoalScale = 0.85
    public static let oceanShoalDepthVariation = 0.68
    public static let oceanSurfDepth = 0.055
    public static let oceanSurfSlopeLo = 0.0019
    public static let oceanSurfSlopeHi = 0.006
    public static let oceanBreakerSpacing = 0.40
    public static let oceanBreakerWidth = 0.15
    public static let oceanBreakerDepth = 0.29
    public static let oceanBreakerStrength = 0.71
    public static let oceanSurfColor = (r: 0.92, g: 0.95, b: 0.96)
    public static let oceanSurfStrength = 0.98
    public static let oceanSurfNoiseLo = 0.27
    public static let oceanSurfNoiseHi = 0.64
    public static let oceanSurfPlumeCut = 3.0
    public static let oceanSurfScale = 3.1
    public static let oceanSurfDrift = 0.6
    public static let oceanWaveFrequency = 0.55
    public static let oceanWaveAmplitude = 0.045
    public static let oceanWaveLacunarity = 2.3
    public static let oceanWaveGain = 0.7
    public static let oceanWaveFadeLo = 0.2
    public static let oceanWaveFadeHi = 0.8
    public static let oceanWaveDriftX = 0.21
    public static let oceanWaveDriftZ = 0.13
    public static let oceanWaveOctaveSpeedup = 0.35

    public static let wetMeadowMaxCells = 200

    public static let remnantMinBandCoverage = 0.5

    @inline(__always)
    public static func isWetMeadow(pondCells: Int, banded: Bool) -> Bool {
        !banded && pondCells < wetMeadowMaxCells
    }

    public static let wetMeadowVegetation = 0.85
    public static let wetMeadowColor = (r: 0.07, g: 0.16, b: 0.06)
    public static let wetMeadowColorMix = 0.7

    public static let coastReachCells = 3
    public static let beachMaxWidthCells = 4.0
    public static let beachBackshoreFadeCells = 2.0
    public static let beachReliefRadiusCells = 8
    public static let beachReliefLo = 0.020
    public static let beachReliefHi = 0.042
    public static let beachOpenRadiusCells = 10
    public static let beachOpenLo = 0.40
    public static let beachOpenHi = 0.50
    public static let beachExposedShare = 0.2
    public static let beachSupplyMinCells = 300.0
    public static let beachSupplyFullCells = 6000.0
    public static let beachSupplyFloor = 0.5
    public static let beachSupplyReachCells = 16.0
    public static let beachSupplyReliefCut = 0.5
    public static let beachSupplyNoiseCut = 0.7
    public static let beachNoiseCells = 30.0
    public static let beachNoiseAmplitude = 0.6
    public static let beachPotentialLo = 0.30
    public static let beachPotentialHi = 0.90
    public static let cliffRiseRadiusCells = 3
    public static let cliffRiseLo = 0.012
    public static let cliffRiseHi = 0.024
    public static let cliffFaceSlopeLo = 0.0024
    public static let cliffFaceSlopeHi = 0.0036
    public static let cliffExposedBoost = 0.3
    public static let beachHeightLo = 0.004
    public static let beachHeightHi = 0.011
    public static let deltaIslandMaxHeight = 0.003
    public static let mouthClearCells = 8
    public static let deltaIslandBeachCells = 2.6
    public static let deltaIslandMinSediment = 0.03
    public static let beachSlopeLo = 0.0042
    public static let beachSlopeHi = 0.0058
    public static let beachWaterlineHeight = 0.003
    public static let cliffCoastSlopeLo = 0.006
    public static let cliffCoastSlopeHi = 0.011

    public static let plumeMinDischargeCells = 3200.0
    public static let plumeFullDischargeCells = 18000.0
    public static let plumeFullRelief = 0.5
    public static let plumeReliefFloor = 0.3

    public static let plumeDecayCells = 18.0
    public static let plumeCutoffDecays = 3.5
    public static let plumeBandCells = 8.0
    public static let plumeCoreCells = 2.5
    public static let plumeUpstreamPenalty = 2.0

    public static let oceanPlumeLod = 1.0
    public static let oceanPlumeOpacity = 0.85
    public static let oceanPlumeColor = (r: 0.20, g: 0.45, b: 0.34)

    public static let barSandYearsLo = 400.0
    public static let barSandYearsHi = 1500.0
    public static let barSandReachLo = 0.8
    public static let barSandReachHi = 1.2

    public static let barSandNeighboursLo = 1.5
    public static let barSandNeighboursHi = 3.5
    public static let barSandNeighbourMin = 0.05

    @inline(__always)
    public static func barSand(age: Double, lineDistanceWidths: Double) -> Double {
        guard age >= 0, lineDistanceWidths.isFinite else { return 0 }
        return (1 - smoothstep(barSandYearsLo, barSandYearsHi, age))
            * (1 - smoothstep(barSandReachLo, barSandReachHi, lineDistanceWidths))
    }

    public static let barPioneerVeg = 0.40
    public static let barPioneerYearsLo = 300.0
    public static let barPioneerYearsHi = 1500.0

    @inline(__always)
    public static func barPioneer(age: Double) -> Double {
        guard age >= 0 else { return 0 }
        return barPioneerVeg * (1 - smoothstep(barPioneerYearsLo, barPioneerYearsHi, age))
    }

    public static let barScrollPeriodYears = 400.0
    public static let barScrollMinSpacingLo = 2.0
    public static let barScrollMinSpacingHi = 3.5
    public static let barScrollFadeYearsLo = 8000.0
    public static let barScrollFadeYearsHi = 20000.0
    public static let barScrollVegGain = 0.10

    @inline(__always)
    public static func barScroll(age: Double, gradientYearsPerCell: Double) -> Double {
        guard age >= 0, barScrollPeriodYears > 0, gradientYearsPerCell > 1e-9,
              gradientYearsPerCell.isFinite else { return 0 }
        let spacing = barScrollPeriodYears / gradientYearsPerCell
        let amp = smoothstep(barScrollMinSpacingLo, barScrollMinSpacingHi, spacing)
            * (1 - smoothstep(barScrollFadeYearsLo, barScrollFadeYearsHi, age))
        return -amp * cos(2 * Double.pi * age / barScrollPeriodYears)
    }

    public static let barProtectSand = 0.25

    public static let oxbowReedStart = 0.0
    public static let oxbowReedFull = 0.15
    public static let oxbowArcStart = 1.5
    public static let oxbowArcFull = 2.5
    public static let oxbowArcFadeShare = 0.6
    public static let oxbowReedColor = (r: 0.27, g: 0.29, b: 0.14)
    public static let oxbowReedTint = 0.6
    public static let oxbowReedVeg = 0.12
    public static let oxbowArcVeg = 0.40

    @inline(__always)
    public static func oxbowStages(age: Double, maxAge: Double) -> (reed: Double, arc: Double) {
        let v = oxbowVisibleYears
        guard age >= 0, v > 0 else { return (0, 0) }
        let arcIn = smoothstep(oxbowArcStart * v, oxbowArcFull * v, age)
        let reed = smoothstep(oxbowReedStart * v, oxbowReedFull * v, age) * (1 - arcIn)
        let arcOut = maxAge > 0 ? 1 - smoothstep(oxbowArcFadeShare * maxAge, maxAge, age) : 1
        return (reed, arcIn * arcOut)
    }

    public static let barSandColor = (r: 0.70, g: 0.65, b: 0.54)
    public static let barSandWetColor = (r: 0.52, g: 0.48, b: 0.40)
    public static let barRoughness = 0.86

    public static let beachDryColor = (r: 0.82, g: 0.75, b: 0.55)
    public static let beachWetColor = (r: 0.33, g: 0.30, b: 0.22)
    public static let beachWetHeight = 0.0008
    public static let beachEdgeLo = 0.32
    public static let beachEdgeHi = 0.82
    public static let beachBlendHeight = 0.001

    public static let ribbonBendDepth = 0.35
    public static let ribbonShoalColor = (r: 0.46, g: 0.50, b: 0.42)
    public static let ribbonShoalMix = 0.45

    public static let ribbonWaterline = 0.35
    public static let ribbonWaterlineJitter = 0.15
    public static let ribbonWaterlineScale = 3.0
    public static let ribbonWaterlineReach = 1 - ribbonWaterline + ribbonWaterlineJitter
    public static let corridorShoreFraction = 1 - ribbonWaterline
    public static let corridorShoreBendShift = 0.18
    public static let ribbonWaterlineReachMin = 0.3
    public static let ribbonWaterlineInner =
        (1 - ribbonWaterline - ribbonWaterlineJitter) / ribbonWaterlineReach
    public static let ribbonWaterlineLift = 0.03
    public static let ribbonCenterClearance = 0.02
    public static let ribbonCenterRaiseMax = 0.04
    public static let ribbonVisibleLo = 0.05
    public static let ribbonVisibleHi = 0.75
    @inline(__always)
    public static func ribbonVisibleWidth(_ alpha: Double) -> Double {
        let t = min(1, max(0, (alpha - ribbonVisibleLo) / (ribbonVisibleHi - ribbonVisibleLo)))
        return t * t * (3 - 2 * t)
    }

    public static let ribbonBankOpacity = 0.12
    public static let ribbonBankColor = (r: 0.11, g: 0.13, b: 0.07)
    public static let waterBedColor = (r: 0.11, g: 0.13, b: 0.08)
    public static let ribbonRippleFrequency = 3.0
    public static let ribbonRippleAmplitude = 0.04
    public static let ribbonRippleStretch = 0.4
    public static let ribbonRippleSpeed = 1.5

    public static let ribbonSlopeWindowCells = 3.0
    public static let ribbonSlopeLo = 0.001
    public static let ribbonSlopeHi = 0.006
    public static let ribbonRiffleBendLo = 0.2
    public static let ribbonRiffleBendHi = 0.6
    public static let ribbonRiffleSpacingWidths = 6.0
    public static let ribbonRiffleMinWidthCells = 2.0
    public static let ribbonRiffleSteepShare = 0.6
    public static let ribbonWhiteSlopeLo = 0.004
    public static let ribbonWhiteSlopeHi = 0.012
    public static let ribbonConstrictionLo = 0.15
    public static let ribbonConstrictionHi = 0.4
    public static let ribbonConfluenceLo = 0.05
    public static let ribbonConfluenceHi = 0.5
    public static let ribbonWhiteRiffleShare = 0.6

    public static let waterRiffleColor = (r: 0.06, g: 0.15, b: 0.14)
    public static let waterRiffleDepth = 0.6
    public static let waterFoamColor = (r: 0.80, g: 0.85, b: 0.86)
    public static let waterFoamAmount = 0.9
    public static let waterFoamScale = 6.0
    public static let waterRiverSpecular = 0.25
    public static let waterLakeColor = (r: 0.008, g: 0.040, b: 0.095)
    public static let waterCloudReflection = 0.6

    public static let rasterSteepLo = 0.3
    public static let rasterSteepHi = 0.8

    @inline(__always)
    public static func ribbonBendShift(across: Double, bend: Double) -> Double {
        ribbonBendDepth * ribbonOutward(across: across, bend: bend)
    }

    @inline(__always)
    public static func ribbonOutward(across: Double, bend: Double) -> Double {
        -(2 * across - 1) * max(-1, min(1, bend))
    }
}
