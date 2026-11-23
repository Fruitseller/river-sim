import SimCore

public enum ForestCanopyMask {

    public static func clumpField(n: Int, world: Double) -> [Float] {
        guard n > 0 else { return [] }
        let scale = CanopyRender.clumpFrequency * world / Double(n)
        let clearScale = CanopyRender.clearingFrequency * world / Double(n)
        var field = [Float](repeating: 0, count: n * n)
        field.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let v = clumpNoise((Double(i) + 0.5) * scale, (Double(j) + 0.5) * scale)
                        let c = clumpNoise((Double(i) + 0.5) * clearScale + 41.3,
                                           (Double(j) + 0.5) * clearScale + 7.9)
                        let clearing = 1 - smoothstep(CanopyRender.clearingLo, CanopyRender.clearingHi, c)
                        pf[j * n + i] = Float(v - CanopyRender.clumpMean - clearing * CanopyRender.clearingDepth)
                    }
                }
            }
        }
        return field
    }

    public static func riparianField(n: Int, world: Double) -> [Float] {
        guard n > 0 else { return [] }
        let scale = CanopyRender.riparianFrequency * world / Double(n)
        var field = [Float](repeating: 0, count: n * n)
        field.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        pf[j * n + i] = Float(clumpNoise((Double(i) + 0.5) * scale + 113.7,
                                                         (Double(j) + 0.5) * scale + 61.2))
                    }
                }
            }
        }
        return field
    }

    public struct Riparian {
        public let distance: [UInt8]
        public let noise: [Float]
        public let colors: [UInt8]
        public let baseBlock: [UInt8]

        public init(distance: [UInt8], noise: [Float], colors: [UInt8], baseBlock: [UInt8] = []) {
            self.distance = distance
            self.noise = noise
            self.colors = colors
            self.baseBlock = baseBlock
        }

        func fits(_ count: Int) -> Bool {
            distance.count == count && noise.count == count && colors.count == count * 4
        }
    }

    @inline(__always)
    static func riparianCover(distance: Double, noise: Double, rock: Double, sand: Double) -> Double {
        let t = smoothstep(CanopyRender.riparianGapLo, CanopyRender.riparianGapHi, noise)
        guard t > 0 else { return 0 }
        let width = CanopyRender.riparianWidthLo
            + (CanopyRender.riparianWidthHi - CanopyRender.riparianWidthLo)
            * smoothstep(CanopyRender.riparianGapHi, 0.62, noise)
        let near = 1 - smoothstep(width, width + 1, distance)
        return CanopyRender.riparianDensity * t * near
            * (1 - smoothstep(CanopyRender.riparianRockLo, CanopyRender.riparianRockHi, rock))
            * (1 - smoothstep(CanopyRender.riparianSandLo, CanopyRender.riparianSandHi, sand))
    }

    public static func target(_ terrain: Terrain, surfaces: [UInt8], colors: [UInt8],
                              bandCore: [Double], waterBytes: [UInt8], wetMeadow: [Bool],
                              barSand: [Float], clump: [Float], riparianNoise: [Float],
                              protect: [UInt8] = [])
        -> (mask: [UInt8], distance: [UInt8]) {
        let water = WaterProtectMask.canopyGuard(n: terrain.cfg.n, bandCoverage: bandCore,
                                                 waterBytes: waterBytes, wetMeadow: wetMeadow,
                                                 barSand: barSand)
        let mask = bytes(terrain, surfaces: surfaces, protect: water.blocked, clump: clump,
                         riparian: Riparian(distance: water.distance, noise: riparianNoise,
                                            colors: colors, baseBlock: protect))
        return (mask, water.distance)
    }

    static func clumpNoise(_ x: Double, _ y: Double) -> Double {
        var px = x, py = y, value = 0.0, amplitude = 0.55
        for _ in 0..<3 {
            value += valueNoise(px, py) * amplitude
            px = px * 2.03 + 17.1
            py = py * 2.03 + 9.2
            amplitude *= 0.48
        }
        return value
    }

    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy)
        let c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * ux, bottom = c + (d - c) * ux
        return (top + (bottom - top) * uy) * 0.5 + 0.5
    }

    private static func hash(_ x: Double, _ y: Double) -> Double {
        let kx = 0.3183099, ky = 0.3678794
        let hx = x * kx + ky, hy = y * ky + kx
        let p = hx * hy * (hx + hy)
        let inner = p - p.rounded(.down)
        let q = 16 * kx * inner
        return -1 + 2 * (q - q.rounded(.down))
    }

    public static func bytes(_ terrain: Terrain, surfaces: [UInt8], protect: [UInt8],
                             clump: [Float], riparian: Riparian? = nil) -> [UInt8] {
        bytes(terrain, surfaces: surfaces, protect: protect, clump: clump,
              vegetationLo: CanopyRender.vegetationLo, vegetationHi: CanopyRender.vegetationHi,
              clumpGain: CanopyRender.clumpGain, riparian: riparian)
    }

    static func bytes(_ terrain: Terrain, surfaces: [UInt8], protect: [UInt8],
                      clump: [Float], vegetationLo: Double, vegetationHi: Double,
                      clumpGain: Double, riparian: Riparian? = nil) -> [UInt8] {
        let n = terrain.cfg.n
        let cnt = n * n
        let h = terrain.h
        guard n > 2, terrain.cfg.cellSize > 0, h.count == cnt, surfaces.count == cnt * 4,
              protect.count == cnt, clump.count == cnt else {
            return [UInt8](repeating: 0, count: max(cnt, 0))
        }
        let sea = terrain.cfg.sea
        let slopeScale = 2 * RenderContract.heightScale / (terrain.cfg.world / Double(n))
        let rip = riparian?.fits(cnt) == true ? riparian : nil
        var mask = [UInt8](repeating: 0, count: cnt)
        h.withUnsafeBufferPointer { hb in
        surfaces.withUnsafeBufferPointer { sb in
        protect.withUnsafeBufferPointer { pb in
        clump.withUnsafeBufferPointer { cb in
        mask.withUnsafeMutableBufferPointer { mb in
            let ph = hb.baseAddress!, ps = sb.baseAddress!, pp = pb.baseAddress!
            let pc = cb.baseAddress!, pm = mb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let k = j * n + i
                        if pp[k] != 0 { continue }
                        let v = ph[k]
                        let shore = smoothstep(sea + CanopyRender.shoreLo,
                                               sea + CanopyRender.shoreHi, v)
                        let ripShore = smoothstep(sea + CanopyRender.riparianShoreLo,
                                                  sea + CanopyRender.riparianShoreHi, v)
                        if shore <= 0 && ripShore <= 0 { continue }
                        let veg = Double(ps[k * 4]) / 255
                        let cold = Double(ps[k * 4 + 2]) / 255
                        let inner = i > 1 && i < n - 2 && j > 1 && j < n - 2
                        let slope = inner ? Terrain.macroSlope(ph, k, n) * slopeScale : 0
                        let baseOpen = rip.map { $0.baseBlock.count != cnt || $0.baseBlock[k] == 0 } ?? true
                        var cover = smoothstep(vegetationLo, vegetationHi,
                                               veg + Double(pc[k]) * clumpGain) * shore
                            * (baseOpen ? 1 : 0)
                            * (1 - smoothstep(CanopyRender.wallSlopeLo, CanopyRender.wallSlopeHi, slope))
                        if let rip, rip.distance[k] != 255 {
                            cover = max(cover, ripShore * riparianCover(
                                distance: Double(rip.distance[k]), noise: Double(rip.noise[k]),
                                rock: Double(ps[k * 4 + 1]) / 255,
                                sand: Double(rip.colors[k * 4 + 3]) / 255)
                                * (1 - smoothstep(CanopyRender.riparianWallSlopeLo,
                                                  CanopyRender.riparianWallSlopeHi, slope)))
                        }
                        let f = cover
                            * (1 - smoothstep(CanopyRender.coldLo, CanopyRender.coldHi, cold))
                        pm[k] = byte01(f)
                    }
                }
            }
        }}}}}
        return mask
    }

    public static func regrow(_ memory: inout [Float], toward target: [UInt8],
                              dtYears: Double, tau: Double,
                              wet: WetNow? = nil, retreatTau: Double = 0,
                              fast: [Bool] = [], fastTau: Double = 0) -> [UInt8] {
        guard !target.isEmpty else {
            memory = []
            return []
        }
        if memory.count != target.count {
            memory = target.map { Float($0) / 255 }
            return target
        }
        guard tau > 0 else {
            memory = target.map { Float($0) / 255 }
            return target
        }
        let safeDt = (dtYears.isFinite && dtYears > 0) ? dtYears : 0.0
        let rise = Float(Terrain.relaxFraction(dt: safeDt, tau: tau))
        let hasFast = fast.count == target.count && fastTau > 0 && fastTau.isFinite
        let riseFast = hasFast ? Float(Terrain.relaxFraction(dt: safeDt, tau: fastTau)) : rise
        let gradual = safeDt > 0 && retreatTau > 0 && retreatTau.isFinite && wet?.fits(target.count) == true
        let fall = gradual ? Float(Terrain.relaxFraction(dt: safeDt, tau: retreatTau)) : 1
        let probe = gradual ? wet! : WetNow(bandCoverage: [], waterBytes: [], bandThreshold: 1)
        var out = target
        memory.withUnsafeMutableBufferPointer { mb in
        out.withUnsafeMutableBufferPointer { ob in
        probe.bandCoverage.withUnsafeBufferPointer { cb in
        probe.waterBytes.withUnsafeBufferPointer { wb in
            let pm = mb.baseAddress!, po = ob.baseAddress!
            let pc = cb.isEmpty ? nil : cb.baseAddress, pw = wb.isEmpty ? nil : wb.baseAddress
            let band = probe.bandThreshold
            let river = probe.riverThreshold, lake = probe.lakeThreshold
            for k in 0..<target.count {
                let t = Float(po[k]) / 255
                let m = pm[k]
                if t <= m {
                    if !gradual || fall >= 1 || t == m { pm[k] = t; continue }
                    let isWet = (pc != nil && pc![k] >= band)
                        || (pw != nil && (pw![k * 4] >= river || pw![k * 4 + 1] >= lake))
                    if isWet { pm[k] = t; continue }
                    let next = min(1.0, max(t, m + (t - m) * fall))
                    pm[k] = next
                    po[k] = UInt8((next * 255).rounded())
                    continue
                }
                let next = min(1.0, max(0.0, m + (t - m) * (hasFast && fast[k] ? riseFast : rise)))
                pm[k] = next
                po[k] = UInt8((next * 255).rounded())
            }
        }}}}
        return out
    }
}

public struct WetNow {
    public let bandCoverage: [Double]
    public let waterBytes: [UInt8]
    public let bandThreshold: Double
    let riverThreshold = byte01(WaterRender.protectRiverThreshold)
    let lakeThreshold = byte01(WaterRender.protectLakeThreshold)

    public init(bandCoverage: [Double], waterBytes: [UInt8], bandThreshold: Double) {
        self.bandCoverage = bandCoverage
        self.waterBytes = waterBytes
        self.bandThreshold = bandThreshold
    }

    func fits(_ count: Int) -> Bool {
        (bandCoverage.isEmpty || bandCoverage.count == count)
            && (waterBytes.isEmpty || waterBytes.count == count * 4)
    }
}
