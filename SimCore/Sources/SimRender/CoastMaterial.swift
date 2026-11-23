import Foundation
import SimCore

public enum CoastMaterial {

    public struct Shore: Sendable {
        public let distance: [UInt8]
        public let beachWidth: [Float]
        public let beachReach: [Float]
        public let cliffReach: [Float]
        public let cliff: [Float]

        public static let empty = Shore(distance: [], beachWidth: [], beachReach: [], cliffReach: [], cliff: [])
    }

    static var distanceCap: Int {
        min(254, max(WaterRender.coastReachCells, Int(WaterRender.beachMaxWidthCells.rounded(.up))) + 1)
    }

    public static func seaDistance(_ terrain: Terrain) -> [UInt8] {
        shoreSeeds(terrain).distance
    }

    static func shoreSeeds(_ terrain: Terrain) -> (distance: [UInt8], origin: [Int32], seeds: [Int]) {
        let n = terrain.cfg.n
        guard n > 0, terrain.h.count == n * n else { return ([], [], []) }
        let cap = UInt8(distanceCap)
        let sea = terrain.cfg.sea
        let h = terrain.h
        var dist = [UInt8](repeating: cap, count: n * n)
        var origin = [Int32](repeating: -1, count: n * n)
        var sea8 = [UInt8](repeating: 0, count: n * n)
        for k in 0..<(n * n) where h[k] <= sea { dist[k] = 0; sea8[k] = 1 }
        var rowNear = [UInt8](repeating: 0, count: n * n)
        sea8.withUnsafeBufferPointer { mb in
        rowNear.withUnsafeMutableBufferPointer { rb in
            let pm = mb.baseAddress!, pr = rb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        var v = pm[j * n + i]
                        if i > 0 { v |= pm[j * n + i - 1] }
                        if i < n - 1 { v |= pm[j * n + i + 1] }
                        pr[j * n + i] = v
                    }
                }
            }
        }}
        var seeds: [Int] = []
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                guard dist[k] != 0 else { continue }
                var near = rowNear[k]
                if j > 0 { near |= rowNear[k - n] }
                if j < n - 1 { near |= rowNear[k + n] }
                if near != 0 { seeds.append(k) }
            }
        }
        var queue = seeds
        for k in seeds { dist[k] = 1; origin[k] = Int32(k) }
        var head = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            let d = dist[k]
            guard d < cap else { continue }
            let i = k % n, j = k / n
            for nj in max(0, j - 1)...min(n - 1, j + 1) {
                for ni in max(0, i - 1)...min(n - 1, i + 1) {
                    let nb = nj * n + ni
                    if dist[nb] > d + 1 {
                        dist[nb] = d + 1
                        origin[nb] = origin[k]
                        queue.append(nb)
                    }
                }
            }
        }
        return (dist, origin, seeds)
    }

    public static func shore(_ terrain: Terrain) -> Shore {
        let n = terrain.cfg.n
        let (dist, origin, seeds) = shoreSeeds(terrain)
        guard n > 2, !dist.isEmpty else { return Shore(distance: dist, beachWidth: [], beachReach: [], cliffReach: [], cliff: []) }
        let h = terrain.h, sea = terrain.cfg.sea

        let r = max(1, WaterRender.beachOpenRadiusCells)
        var sum = [Int32](repeating: 0, count: (n + 1) * (n + 1))
        for j in 0..<n {
            var row: Int32 = 0
            for i in 0..<n {
                if h[j * n + i] <= sea { row += 1 }
                sum[(j + 1) * (n + 1) + i + 1] = sum[j * (n + 1) + i + 1] + row
            }
        }
        func openness(_ i: Int, _ j: Int) -> Double {
            let i0 = max(0, i - r), i1 = min(n - 1, i + r), j0 = max(0, j - r), j1 = min(n - 1, j + r)
            let s = sum[(j1 + 1) * (n + 1) + i1 + 1] - sum[j0 * (n + 1) + i1 + 1]
                - sum[(j1 + 1) * (n + 1) + i0] + sum[j0 * (n + 1) + i0]
            return Double(s) / Double((i1 - i0 + 1) * (j1 - j0 + 1))
        }
        let rr = max(1, WaterRender.beachReliefRadiusCells)
        func relief(_ i: Int, _ j: Int) -> Double {
            var top = h[j * n + i]
            for jj in max(0, j - rr)...min(n - 1, j + rr) {
                for ii in max(0, i - rr)...min(n - 1, i + rr) { top = max(top, h[jj * n + ii]) }
            }
            return top - h[j * n + i]
        }
        let cr = max(1, WaterRender.cliffRiseRadiusCells)
        func rise(_ i: Int, _ j: Int) -> Double {
            var top = h[j * n + i]
            for jj in max(0, j - cr)...min(n - 1, j + cr) {
                for ii in max(0, i - cr)...min(n - 1, i + cr) { top = max(top, h[jj * n + ii]) }
            }
            return top - h[j * n + i]
        }
        let supply = mouthSupply(terrain, seeds: seeds)
        let sediment = terrain.sed

        var width = [Float](repeating: 0, count: n * n)
        var cliff = [Float](repeating: 0, count: n * n)
        for (index, k) in seeds.enumerated() {
            let i = k % n, j = k / n
            guard i >= 2, i < n - 2, j >= 2, j < n - 2 else { continue }
            let (w, c) = beach(relief: relief(i, j), rise: rise(i, j), openness: openness(i, j),
                               supply: supply[index], noise: alongShoreNoise(i, j))
            let deltaFlat = h[k] <= sea + WaterRender.deltaIslandMaxHeight
                && (supply[index] > 0.25 || (sediment.count == n * n && sediment[k] >= WaterRender.deltaIslandMinSediment))
            width[k] = Float(deltaFlat ? min(w, WaterRender.deltaIslandBeachCells) : w)
            cliff[k] = Float(c)
        }
        var inherited = width, inheritedCliff = cliff
        for k in 0..<(n * n) {
            let o = Int(origin[k])
            if o >= 0, o != k { inherited[k] = width[o]; inheritedCliff[k] = cliff[o] }
        }
        for k in deltaIslands(terrain) {
            inherited[k] = Float(WaterRender.deltaIslandBeachCells)
            inheritedCliff[k] = 0
        }
        var reach = beachReach(terrain, seeds: seeds, width: inherited,
                               fadeCells: WaterRender.beachBackshoreFadeCells)
        clearRiverBeds(terrain, seeds: seeds, reach: &reach)
        let surfWidths = [Float](repeating: Float(WaterRender.coastReachCells), count: n * n)
        var surf = beachReach(terrain, seeds: seeds, width: surfWidths)
        if sediment.count == n * n {
            for k in 0..<(n * n) where h[k] > sea && h[k] <= sea + WaterRender.deltaIslandMaxHeight {
                if sediment[k] >= WaterRender.deltaIslandMinSediment { surf[k] = 0 }
            }
        }
        return Shore(distance: dist, beachWidth: inherited, beachReach: reach,
                     cliffReach: surf, cliff: inheritedCliff)
    }

    static func clearRiverBeds(_ terrain: Terrain, seeds: [Int], reach: inout [Float]) {
        let n = terrain.cfg.n, sea = terrain.cfg.sea
        let h = terrain.h, rec = terrain.receiver, area = terrain.area
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        guard reach.count == n * n, rec.count == n * n, area.count == n * n,
              cellArea > 0, cellArea.isFinite else { return }
        let minArea = terrain.cfg.renderMinCells * cellArea
        for k in seeds {
            let r = Int(rec[k])
            guard r >= 0, r < n * n, h[r] <= sea, area[k] >= minArea else { continue }
            var cur = k
            for _ in 0..<WaterRender.mouthClearCells {
                let w = WaterRender.ribbonHalfWidthCells(dischargeCells: area[cur] / cellArea,
                                                         referenceCells: terrain.cfg.renderMinCells)
                let ci = cur % n, cj = cur / n, rad = Int((w + 1).rounded(.up))
                for jj in max(0, cj - rad)...min(n - 1, cj + rad) {
                    for ii in max(0, ci - rad)...min(n - 1, ci + rad) {
                        let d = Double((ii - ci) * (ii - ci) + (jj - cj) * (jj - cj)).squareRoot()
                        let keep = Float(smoothstep(w - 0.5, w + 0.5, d))
                        reach[jj * n + ii] *= keep
                    }
                }
                var up = -1, upArea = 0.0
                for jj in max(0, cj - 1)...min(n - 1, cj + 1) {
                    for ii in max(0, ci - 1)...min(n - 1, ci + 1) {
                        let nb = jj * n + ii
                        if Int(rec[nb]) == cur && area[nb] > upArea { up = nb; upArea = area[nb] }
                    }
                }
                if up < 0 || upArea < minArea { break }
                cur = up
            }
        }
    }

    static func beachReach(_ terrain: Terrain, seeds: [Int], width: [Float],
                           fadeCells: Double = 1) -> [Float] {
        let n = terrain.cfg.n, h = terrain.h, sea = terrain.cfg.sea
        var out = [Float](repeating: 0, count: n * n)
        for k in seeds where width[k] > 0 {
            let w = Double(width[k]), r = Int(w.rounded(.up))
            let backshore = smoothstep(WaterRender.deltaIslandBeachCells, WaterRender.beachMaxWidthCells, w)
            let fade = 1 + (fadeCells - 1) * backshore
            let i = k % n, j = k / n
            for jj in max(0, j - r)...min(n - 1, j + r) {
                for ii in max(0, i - r)...min(n - 1, i + r) {
                    let nb = jj * n + ii
                    guard h[nb] > sea else { continue }
                    let dx = Double(ii - i), dz = Double(jj - j)
                    let distance = (dx * dx + dz * dz).squareRoot()
                    let reach = Float(clamp01((w - distance) / fade))
                    out[nb] = max(out[nb], reach)
                }
            }
        }
        return out
    }

    static func deltaIslands(_ terrain: Terrain) -> [Int] {
        let n = terrain.cfg.n
        guard n > 2, terrain.h.count == n * n else { return [] }
        let h = terrain.h, sea = terrain.cfg.sea, top = sea + WaterRender.deltaIslandMaxHeight
        var seen = [Bool](repeating: false, count: n * n)
        var out: [Int] = [], comp: [Int] = [], stack: [Int] = []
        for start in 0..<(n * n) where !seen[start] && h[start] > sea && h[start] <= top {
            comp.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(start); seen[start] = true
            var attached = false
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                for nj in max(0, j - 1)...min(n - 1, j + 1) {
                    for ni in max(0, i - 1)...min(n - 1, i + 1) {
                        let nb = nj * n + ni
                        if h[nb] > top { attached = true; continue }
                        if h[nb] > sea && !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
            if !attached { out.append(contentsOf: comp) }
        }
        return out
    }

    struct Calibration {
        var reliefLo = WaterRender.beachReliefLo, reliefHi = WaterRender.beachReliefHi
        var openLo = WaterRender.beachOpenLo, openHi = WaterRender.beachOpenHi
        var exposedShare = WaterRender.beachExposedShare
        var supplyReliefCut = WaterRender.beachSupplyReliefCut
        var noiseAmplitude = WaterRender.beachNoiseAmplitude
        var supplyNoiseCut = WaterRender.beachSupplyNoiseCut
        var potentialLo = WaterRender.beachPotentialLo, potentialHi = WaterRender.beachPotentialHi
        var maxWidth = WaterRender.beachMaxWidthCells
        var cliffLo = WaterRender.cliffRiseLo, cliffHi = WaterRender.cliffRiseHi
        var cliffExposedBoost = WaterRender.cliffExposedBoost

        static let calibrated = Calibration()
    }

    static func beach(relief: Double, rise: Double, openness: Double, supply: Double, noise: Double,
                      _ c: Calibration = .calibrated) -> (width: Double, cliff: Double) {
        let effective = relief * (1 - c.supplyReliefCut * supply)
        let plain = 1 - smoothstep(c.reliefLo, c.reliefHi, effective)
        let shelter = 1 - smoothstep(c.openLo, c.openHi, openness)
        var potential = plain * (c.exposedShare + (1 - c.exposedShare) * max(shelter, supply))
        potential += c.noiseAmplitude * (1 - c.supplyNoiseCut * supply) * (noise - 0.5)
        let strength = smoothstep(c.potentialLo, c.potentialHi, potential)
        let exposure = smoothstep(c.openLo, c.openHi, openness)
        let steep = rise * (1 + c.cliffExposedBoost * exposure)
        let rock = smoothstep(c.cliffLo, c.cliffHi, steep)
        return (strength * c.maxWidth, rock * (1 - strength))
    }

    static func mouthSupply(_ terrain: Terrain, seeds: [Int]) -> [Double] {
        let n = terrain.cfg.n, sea = terrain.cfg.sea
        let h = terrain.h, rec = terrain.receiver, area = terrain.area
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        var out = [Double](repeating: 0, count: seeds.count)
        guard rec.count == n * n, area.count == n * n, cellArea > 0, cellArea.isFinite else { return out }
        let lo = WaterRender.beachSupplyMinCells, hi = WaterRender.beachSupplyFullCells
        var mouths: [(i: Int, j: Int, weight: Double)] = []
        for k in seeds {
            let r = Int(rec[k])
            guard r >= 0, r < n * n, h[r] <= sea else { continue }
            let q = area[k] / cellArea
            guard q.isFinite, q >= lo else { continue }
            mouths.append((k % n, k / n, clamp01(log(q / lo) / log(hi / lo))))
        }
        guard !mouths.isEmpty else { return out }
        let reach = WaterRender.beachSupplyReachCells
        for (index, k) in seeds.enumerated() {
            let i = k % n, j = k / n
            var best = 0.0
            for m in mouths {
                let d = (Double((m.i - i) * (m.i - i) + (m.j - j) * (m.j - j))).squareRoot()
                guard d < reach else { continue }
                let weight = WaterRender.beachSupplyFloor + (1 - WaterRender.beachSupplyFloor) * m.weight
                best = max(best, weight * (1 - smoothstep(0, reach, d)))
            }
            out[index] = best
        }
        return out
    }

    static func alongShoreNoise(_ i: Int, _ j: Int) -> Double {
        let scale = WaterRender.beachNoiseCells
        func hash(_ x: Int, _ y: Int) -> Double {
            var v = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            v = (v ^ (v >> 13)) &* 1_274_126_177
            v ^= v >> 16
            return Double(v & 0xFFFF) / 65535
        }
        func value(_ x: Double, _ y: Double) -> Double {
            let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
            let fx = x - Double(xi), fy = y - Double(yi)
            let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
            let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
            return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
        }
        let x = Double(i) / scale, y = Double(j) / scale
        return 0.65 * value(x, y) + 0.35 * value(x * 2.3 + 17.1, y * 2.3 + 5.7)
    }

    @inline(__always)
    static func inSurf(_ distance: UInt8) -> Bool {
        distance >= 1 && Int(distance) <= WaterRender.coastReachCells
    }

    @inline(__always)
    public static func sand(distance: UInt8, width: Float, slope: Double, height: Double) -> Double {
        guard distance >= 1, height > 0 else { return 0 }
        let reach = clamp01(Double(width) - Double(distance - 1))
        guard reach > 0 else { return 0 }
        return sand(reach: Float(reach), slope: slope, height: height)
    }

    @inline(__always)
    public static func sand(reach: Float, slope: Double, height: Double) -> Double {
        guard height > 0, reach > 0 else { return 0 }
        let flat = max(1 - smoothstep(WaterRender.beachSlopeLo, WaterRender.beachSlopeHi, slope),
                       1 - smoothstep(WaterRender.beachWaterlineHeight,
                                      2 * WaterRender.beachWaterlineHeight, height))
        return Double(reach) * flat
            * (1 - smoothstep(WaterRender.beachHeightLo, WaterRender.beachHeightHi, height))
    }

    @inline(__always)
    public static func cliff(distance: UInt8, slope: Double, relief: Float) -> Double {
        guard inSurf(distance) else { return 0 }
        return cliff(reach: 1, slope: slope, relief: relief)
    }

    @inline(__always)
    public static func cliff(reach: Float, slope: Double, relief: Float) -> Double {
        let face = smoothstep(WaterRender.cliffFaceSlopeLo, WaterRender.cliffFaceSlopeHi, slope)
        return Double(reach) * max(smoothstep(WaterRender.cliffCoastSlopeLo, WaterRender.cliffCoastSlopeHi, slope),
                                   Double(relief) * face)
    }
}
