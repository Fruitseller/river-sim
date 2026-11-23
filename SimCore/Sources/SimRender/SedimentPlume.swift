import Foundation
import SimCore

public enum SedimentPlume {

    public struct Mouth: Equatable {
        public let landCell: Int
        public let seaCell: Int
        public let dischargeCells: Double
        public let relief: Double
    }

    public static func mouths(_ terrain: Terrain) -> [Mouth] {
        let n = terrain.cfg.n, cnt = n * n
        let h = terrain.h, rec = terrain.receiver, area = terrain.area
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        guard n > 2, h.count == cnt, rec.count == cnt, area.count == cnt,
              cellArea > 0, cellArea.isFinite else { return [] }
        let sea = terrain.cfg.sea

        var label = [Int32](repeating: -1, count: cnt)
        var mouthCells: [Int] = []
        var relief: [Double] = []
        var path: [Int] = []
        for start in 0..<cnt where h[start] > sea && label[start] == -1 {
            path.removeAll(keepingCapacity: true)
            var k = start
            var result: Int32 = -2
            for _ in 0..<cnt {
                if label[k] != -1 { result = label[k]; break }
                path.append(k)
                let r = Int(rec[k])
                if r < 0 || r >= cnt { break }
                if h[r] <= sea {
                    result = Int32(mouthCells.count)
                    mouthCells.append(k)
                    relief.append(0)
                    break
                }
                k = r
            }
            for p in path {
                label[p] = result
                if result >= 0 { relief[Int(result)] = max(relief[Int(result)], h[p] - sea) }
            }
        }

        var out: [Mouth] = []
        for (index, k) in mouthCells.enumerated() {
            let q = area[k] / cellArea
            guard q.isFinite, q >= WaterRender.plumeMinDischargeCells else { continue }
            out.append(Mouth(landCell: k, seaCell: Int(rec[k]),
                             dischargeCells: q, relief: relief[index]))
        }
        return out
    }

    @inline(__always)
    public static func strength(_ mouth: Mouth) -> Double {
        let lo = WaterRender.plumeMinDischargeCells, hi = WaterRender.plumeFullDischargeCells
        let discharge = clamp01(log(max(mouth.dischargeCells, lo) / lo) / log(hi / lo))
        let floor = WaterRender.plumeReliefFloor
        let load = floor + (1 - floor) * clamp01(mouth.relief / WaterRender.plumeFullRelief)
        return discharge * load
    }

    public static func field(_ terrain: Terrain) -> [Float] {
        let n = terrain.cfg.n
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n * n)
        for mouth in mouths(terrain) {
            spread(mouth, strength: strength(mouth), terrain, into: &out)
        }
        return out
    }

    static func spread(_ mouth: Mouth, strength: Double, _ terrain: Terrain,
                       into out: inout [Float]) {
        let n = terrain.cfg.n, sea = terrain.cfg.sea
        guard strength > 0, strength.isFinite, mouth.seaCell >= 0, mouth.seaCell < n * n else { return }
        let decay = WaterRender.plumeDecayCells
        let cutoff = decay * WaterRender.plumeCutoffDecays
        let band = WaterRender.plumeBandCells
        let searchRadius = Int(band.rounded(.up)) + 1
        let half = Int(cutoff.rounded(.up)) + searchRadius
        let size = 2 * half + 1
        let h = terrain.h
        let si = mouth.seaCell % n, sj = mouth.seaCell / n
        let i0 = si - half, j0 = sj - half

        let dx = WaterRender.oceanWaveDriftX, dz = WaterRender.oceanWaveDriftZ
        let dn = max((dx * dx + dz * dz).squareRoot(), 1e-9)
        let cx = dx / dn, cz = dz / dn
        var steps: [(di: Int, dj: Int, cost: Double)] = []
        for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
            let len = (Double(di * di + dj * dj)).squareRoot()
            let along = (Double(di) * cx + Double(dj) * cz) / len
            steps.append((di, dj, len * (1 + WaterRender.plumeUpstreamPenalty * (1 - along) / 2)))
        } }

        var cost = [Double](repeating: .infinity, count: size * size)
        var landDistance = [Float](repeating: -1, count: size * size)
        func distanceToLand(_ gi: Int, _ gj: Int, local: Int) -> Double {
            if landDistance[local] >= 0 { return Double(landDistance[local]) }
            var best = Double((searchRadius + 1) * (searchRadius + 1))
            for dj in -searchRadius...searchRadius {
                let jj = gj + dj
                guard jj >= 0, jj < n else { continue }
                for di in -searchRadius...searchRadius {
                    let ii = gi + di
                    guard ii >= 0, ii < n, h[jj * n + ii] > sea else { continue }
                    best = min(best, Double(di * di + dj * dj))
                }
            }
            let d = best.squareRoot()
            landDistance[local] = Float(d)
            return d
        }

        let start = half * size + half
        cost[start] = 0
        var queue = [start]
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            let ci = c % size, cj = c / size
            for step in steps {
                let li = ci + step.di, lj = cj + step.dj
                guard li >= 0, li < size, lj >= 0, lj < size else { continue }
                let next = cost[c] + step.cost
                let local = lj * size + li
                guard next < cutoff, next < cost[local] else { continue }
                let gi = i0 + li, gj = j0 + lj
                guard gi >= 0, gi < n, gj >= 0, gj < n, h[gj * n + gi] <= sea else { continue }
                guard distanceToLand(gi, gj, local: local) <= band else { continue }
                cost[local] = next
                queue.append(local)
            }
        }

        for local in 0..<(size * size) where cost[local] < cutoff {
            let gi = i0 + local % size, gj = j0 + local / size
            guard gi >= 0, gi < n, gj >= 0, gj < n else { continue }
            let c = cost[local]
            let across = 1 - smoothstep(WaterRender.plumeCoreCells, band,
                                        distanceToLand(gi, gj, local: local))
            let density = Float(strength * exp(-c / decay) * across)
            let k = gj * n + gi
            if density > out[k] { out[k] = density }
        }
    }
}
