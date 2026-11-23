import Foundation

public struct HeightBands: Equatable, Sendable, Codable {
    public var vegFull: Double
    public var vegRamp: Double
    public var vegNone: Double { vegFull + vegRamp }
    public var rockStart: Double
    public var rockFull: Double
    public var snowStart: Double
    public var snowFull: Double
    public var coniferLow: Double
    public var coniferHigh: Double

    public static let legacyAbsolute = HeightBands(
        vegFull: 0.50, vegRamp: 0.18,
        rockStart: 0.58, rockFull: 0.98,
        snowStart: 1.05, snowFull: 1.13,
        coniferLow: 0.26, coniferHigh: 0.48)

    @inline(__always) public func vegetationAltitudeFactor(_ v: Double) -> Double {
        v < vegFull ? 1 : min(1, max(0, 1 - (v - vegFull) / max(1e-6, vegRamp)))
    }

    @inline(__always) public func rockAmount(_ v: Double) -> Double {
        min(1, max(0, (v - rockStart) / max(1e-6, rockFull - rockStart)))
    }

    @inline(__always) public func snowAmount(_ v: Double) -> Double {
        min(1, max(0, (v - snowStart) / max(1e-6, snowFull - snowStart)))
    }

    @inline(__always) public func coniferShare(_ v: Double) -> Double {
        min(0.9, max(0.1, (v - coniferLow) / max(1e-6, coniferHigh - coniferLow)))
    }

    public static func fromLandHeights(_ heights: [Double], cfg: SimConfig,
                                       snowFractions: (ramp: Double, full: Double)? = nil)
        -> HeightBands {
        let snowP = snowFractions.map { (1 - $0.ramp, 1 - $0.full) }
            ?? (cfg.bandSnowPercentile, cfg.bandSnowFullPercentile)
        let raw = [cfg.bandVegFullPercentile, 0.5,
                   cfg.bandRockPercentile, cfg.bandRockFullPercentile,
                   snowP.0, snowP.1,
                   cfg.bandConiferLowPercentile, cfg.bandConiferHighPercentile,
                   0.95]
        let order = raw.indices.sorted { raw[$0] < raw[$1] }
        guard let sorted = Terrain.landHeightQuantiles(heights: heights, sea: cfg.sea,
                                                       probs: order.map { raw[$0] })
        else { return legacyAbsolute }
        var q = [Double](repeating: 0, count: raw.count)
        for (slot, original) in order.enumerated() { q[original] = sorted[slot] }
        let w = max(1e-6, cfg.bandMinRampWidth)
        let reliefSpan = cfg.bandVegRampSpanFactor * (q[8] - q[1])
        var snowStart = q[4]
        if let f = snowFractions, f.ramp <= 0 {
            snowStart = q[4] + 2 * w
        }
        return HeightBands(vegFull: q[0], vegRamp: max(w, reliefSpan),
                           rockStart: q[2], rockFull: max(q[3], q[2] + w),
                           snowStart: snowStart, snowFull: max(q[5], snowStart + w),
                           coniferLow: q[6], coniferHigh: max(q[7], q[6] + w))
    }
}
