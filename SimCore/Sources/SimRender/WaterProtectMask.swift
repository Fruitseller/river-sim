import SimCore

public enum WaterProtectMask {

    public static func bytes(n: Int, bandCoverage: [Double], waterBytes: [UInt8],
                             wetMeadow: [Bool] = [], barSand: [Float] = [],
                             seamCells: Int = WaterRender.protectSeamCells) -> [UInt8] {
        guard n > 0 else { return [] }
        let cnt = n * n
        let riverThresh = byte01(WaterRender.protectRiverThreshold)
        let lakeThresh = byte01(WaterRender.protectLakeThreshold)
        let bandThresh = WaterRender.protectBandThreshold
        let hasBands = bandCoverage.count == cnt
        let hasWater = waterBytes.count == cnt * 4
        let hasMeadow = wetMeadow.count == cnt

        var mask = [UInt8](repeating: 0, count: cnt)
        mask.withUnsafeMutableBufferPointer { mb in
            let pm = mb.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    let isBand = hasBands && bandCoverage[k] >= bandThresh
                    let isWater = hasWater
                        && (waterBytes[k * 4] >= riverThresh || waterBytes[k * 4 + 1] >= lakeThresh)
                    let isMeadow = hasMeadow && wetMeadow[k]
                    pm[k] = (isBand || isWater || isMeadow) ? 255 : 0
                }
            }
        }

        var temp = [UInt8](repeating: 0, count: cnt)
        for _ in 0..<max(0, seamCells) {
            dilate3x3(src: mask, dst: &temp, n: n)
            swap(&mask, &temp)
        }

        if barSand.count == cnt {
            let limit = Float(WaterRender.barProtectSand)
            for k in 0..<cnt where barSand[k] >= limit { mask[k] = 255 }
        }
        return mask
    }

    public static func canopyGuard(n: Int, bandCoverage: [Double], waterBytes: [UInt8],
                                   wetMeadow: [Bool] = [], barSand: [Float] = [])
        -> (blocked: [UInt8], distance: [UInt8]) {
        guard n > 0 else { return ([], []) }
        let cnt = n * n
        let full = bytes(n: n, bandCoverage: bandCoverage, waterBytes: waterBytes,
                         wetMeadow: wetMeadow, seamCells: 0)
        var lakeOnly = waterBytes
        if lakeOnly.count == cnt * 4 {
            for k in stride(from: 0, to: cnt * 4, by: 4) { lakeOnly[k] = 0 }
        }
        let open = bytes(n: n, bandCoverage: bandCoverage, waterBytes: lakeOnly, seamCells: 0)
        var raster = full
        for k in 0..<cnt where open[k] != 0 { raster[k] = 0 }
        let rasterDistance = chebyshev(raster, reach: WaterRender.protectSeamCells, n: n)
        let reach = max(CanopyRender.riparianReachCells, CanopyRender.waterSeamCells)
        let distance = chebyshev(open, reach: reach, n: n)
        var mask = [UInt8](repeating: 0, count: cnt)
        for k in 0..<cnt where Int(distance[k]) <= CanopyRender.waterSeamCells
            || Int(rasterDistance[k]) <= WaterRender.protectSeamCells { mask[k] = 255 }
        if barSand.count == cnt {
            let limit = Float(WaterRender.barProtectSand)
            for k in 0..<cnt where barSand[k] >= limit { mask[k] = 255 }
        }
        return (mask, distance)
    }

    private static func chebyshev(_ core: [UInt8], reach: Int, n: Int) -> [UInt8] {
        let cnt = n * n
        var core = core
        var distance = core.map { $0 != 0 ? UInt8(0) : UInt8(255) }
        var temp = [UInt8](repeating: 0, count: cnt)
        if reach > 0 {
            for step in 1...reach {
                dilate3x3(src: core, dst: &temp, n: n)
                swap(&core, &temp)
                for k in 0..<cnt where core[k] != 0 && distance[k] == 255 { distance[k] = UInt8(step) }
            }
        }
        return distance
    }

    private static func dilate3x3(src: [UInt8], dst: inout [UInt8], n: Int) {
        src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            let ps = sb.baseAddress!, pd = db.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    let jMin = max(0, j - 1), jMax = min(n - 1, j + 1)
                    for i in 0..<n {
                        let iMin = max(0, i - 1), iMax = min(n - 1, i + 1)
                        var hit: UInt8 = 0
                        for nj in jMin...jMax {
                            for ni in iMin...iMax { hit |= ps[nj * n + ni] }
                        }
                        pd[j * n + i] = hit
                    }
                }
            }
        }}
    }
}
