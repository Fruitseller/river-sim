import Foundation
import SimCore

public struct RiverCorridorMesh: Equatable {
    public var vertices: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var colors: [SIMD4<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var uv2s: [SIMD2<Float>] = []
    public var custom: [SIMD4<Float>] = []
    public var indices: [Int32] = []

    public init() {}

    mutating func removeAll() {
        vertices.removeAll(keepingCapacity: true)
        normals.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)
        uvs.removeAll(keepingCapacity: true)
        uv2s.removeAll(keepingCapacity: true)
        custom.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
    }
}

struct BankSurface {
    let h: [Double]
    let n: Int
    let renderGrid: Int
    let hscale: Double

    @inline(__always)
    func height(_ gx: Double, _ gz: Double) -> Double {
        renderSurfaceHeight(h, gx, gz, n: n, renderGrid: renderGrid) * hscale
    }
}

enum CorridorProfile {
    static let columns = 11
    static let topColumn = 1
    static let shoreColumn = 3
    static let footCells = 0.45
    static let leveeFootCells = 0.9
    static let shoreFraction = WaterRender.corridorShoreFraction
    static let shoreBendShift = WaterRender.corridorShoreBendShift
    static let thalwegShift = 0.4
    static let bankBaseCells = 0.35
    static let bankWidthShare = 0.18
    static let bankBendShare = 0.6
    static let depthBase = 0.025
    static let depthPerWidth = 0.26
    static let depthMax = 0.2
    static let riffleShallowing = 0.45
    static let freeboard = 0.006
    static let edgeSearchCells = 2.5
    static let edgeSearchStep = 0.25
    static let maskMarginCells = 0.25
    static func maxReachCells(halfWidthCells hw: Double) -> Double {
        hw + 0.5 + Double(WaterRender.protectSeamCells) - maskMarginCells
    }
    static let lidClearance = 0.02
    static let lidMaxAboveWater = 0.12

    struct Section {
        var offsets = [Double](repeating: 0, count: columns)
        var heights = [Double](repeating: 0, count: columns)
        var depths = [Double](repeating: 0, count: columns)
        var bar = [Double](repeating: 0, count: columns)
        var lid = 0.0
        var waterHalfWidthCells = 0.0
    }

    static func section(halfWidthCells hw: Double, visible: Double,
                        waterLeft: Double, waterRight: Double,
                        bend: Double, riffle: Double, cellSize cs: Double,
                        edges: (Double, Double)? = nil,
                        reachLimit: (Double, Double) = (.infinity, .infinity),
                        surface: (Double) -> Double) -> Section {
        var s = Section()
        let vis = max(0, min(1, visible))
        let ww = hw * vis
        s.waterHalfWidthCells = ww
        let beta = max(-1, min(1, bend))
        func gamma(_ side: Double) -> Double { -side * beta }
        func water(_ c: Double) -> Double {
            guard hw > 1e-9 else { return 0.5 * (waterLeft + waterRight) }
            let u = max(-1, min(1, c / hw))
            return 0.5 * (waterLeft + waterRight) + 0.5 * (waterRight - waterLeft) * u
        }
        let depth = vis * min(depthMax, depthBase + depthPerWidth * 2 * ww * cs)
            * (1 - riffleShallowing * max(0, min(1, riffle)))
        let bankBase = vis * (bankBaseCells + bankWidthShare * hw)
        let thalweg = -thalwegShift * beta * ww
        var col = 0
        func put(_ c: Double, _ y: Double, _ bar: Double) {
            s.offsets[col] = c
            s.heights[col] = y
            s.depths[col] = water(c) - y
            s.bar[col] = bar
            col += 1
        }
        var right: [(Double, Double, Double)] = []
        var left: [(Double, Double, Double)] = []
        for side in [-1.0, 1.0] {
            let g = gamma(side)
            let bar = max(0, -g)
            let shore = ww * (shoreFraction + shoreBendShift * g)
            let limit = max(side < 0 ? reachLimit.0 : reachLimit.1, shore + vis * (footCells + 0.1))
            let reach = min(maxReachCells(halfWidthCells: hw), limit)
            var edge = min(ww + bankBase * (1 - bankBendShare * g), reach - vis * footCells)
            let shoreY = water(side * shore)
            if let edges { edge = min(side < 0 ? edges.0 : edges.1, reach - vis * footCells) }
            edge = max(edge, min(shore, reach - vis * footCells))
            var ground = surface(side * edge)
            if edges == nil, vis > 0, ground < shoreY + freeboard {
                var d = edgeSearchStep
                while d <= edgeSearchCells + 1e-9, edge + d * vis + vis * leveeFootCells <= reach {
                    let g2 = surface(side * (edge + d * vis))
                    if g2 >= shoreY + freeboard { edge += d * vis; ground = g2; break }
                    d += edgeSearchStep
                }
            }
            let top = max(ground, shoreY + freeboard)
            let footAt = min(edge + vis * (top > ground + 1e-9 ? leveeFootCells : footCells), reach)
            let footY = surface(side * footAt)
            let midAt = shore + (edge - shore) * (0.3 - 0.15 * g)
            let midY = shoreY + (top - shoreY) * (0.55 + 0.35 * g)
            let bedAt = 0.5 * (shore + side * thalweg)
            let bedY = water(side * bedAt) - depth * (0.7 + 0.2 * g)
            let entries = [(side * footAt, footY, 0.0), (side * edge, top, bar), (side * midAt, midY, bar),
                           (side * shore, shoreY, bar), (side * bedAt, bedY, bar * 0.5)]
            if side < 0 { left = entries } else { right = entries.reversed() }
        }
        for e in left { put(e.0, e.1, e.2) }
        put(thalweg, water(thalweg) - depth, 0)
        for e in right { put(e.0, e.1, e.2) }
        let waterTop = max(water(s.offsets[shoreColumn]), water(s.offsets[columns - 1 - shoreColumn]))
        var lid = max(waterLeft, waterRight)
        for k in 0..<columns {
            lid = max(lid, s.heights[k], surface(s.offsets[k]))
            if k > 0 { lid = max(lid, surface(0.5 * (s.offsets[k - 1] + s.offsets[k]))) }
        }
        lid = min(lid, waterTop + lidMaxAboveWater)
        s.lid = lid + lidClearance
        for k in 0..<columns where s.heights[k] > lid {
            s.heights[k] = lid
            s.depths[k] = water(s.offsets[k]) - lid
        }
        let lowTop = min(s.heights[topColumn], s.heights[columns - 1 - topColumn]) - freeboard
        for k in (shoreColumn + 1)..<(columns - 1 - shoreColumn) where s.heights[k] > lowTop {
            s.heights[k] = lowTop
            s.depths[k] = water(s.offsets[k]) - lowTop
        }
        for k in 0..<columns where k < shoreColumn || k > columns - 1 - shoreColumn {
            s.depths[k] = min(s.depths[k], 0)
        }
        for k in 1..<columns { s.offsets[k] = max(s.offsets[k], s.offsets[k - 1]) }
        return s
    }
}

enum CorridorSections {
    struct Input {
        var hw: Double, visible: Double
        var waterLeft: Double, waterRight: Double
        var bend: Double, riffle: Double
        var x: Double, z: Double
        var tx: Double, tz: Double
    }
    static let edgeMedianRadius = 2
    static let edgeMeanRadius = 2
    static let innerReachShare = 0.85
    static let curvatureSpan = 2
    static let endRampSamples = 4.0
    static let lidPresence = WaterRender.ribbonVisibleLo

    static func endRamp(_ a: Int, count m: Int) -> Double {
        smoothstep(0, endRampSamples, Double(min(a, m - 1 - a)))
    }

    static func build(_ inputs: [Input], cellSize cs: Double, bank: BankSurface) -> [CorridorProfile.Section] {
        let m = inputs.count
        guard m > 0 else { return [] }
        func surface(_ i: Input) -> (Double) -> Double {
            { c in bank.height(i.x - i.tz * c, i.z + i.tx * c) }
        }
        var limits = [(Double, Double)](repeating: (.infinity, .infinity), count: m)
        if m >= 3 {
            var radius = [Double](repeating: .infinity, count: m)
            var inner = [Double](repeating: 0, count: m)
            for a in 0..<m {
                let a0 = max(0, a - curvatureSpan), a1 = min(m - 1, a + curvatureSpan)
                guard a1 > a0 else { continue }
                let t0 = inputs[a0], t1 = inputs[a1]
                let cross = t0.tx * t1.tz - t0.tz * t1.tx
                let dot = t0.tx * t1.tx + t0.tz * t1.tz
                var len = 0.0
                for b in a0..<a1 {
                    let dx = inputs[b + 1].x - inputs[b].x, dz = inputs[b + 1].z - inputs[b].z
                    len += (dx * dx + dz * dz).squareRoot()
                }
                let angle = abs(atan2(cross, dot))
                guard angle > 1e-6 else { continue }
                radius[a] = len / angle
                inner[a] = cross > 0 ? 1 : -1
            }
            for a in 0..<m where radius[a] < .infinity {
                var r = radius[a]
                for b in max(0, a - curvatureSpan)...min(m - 1, a + curvatureSpan) { r = min(r, radius[b]) }
                let cap = innerReachShare * r
                limits[a] = inner[a] > 0 ? (.infinity, cap) : (cap, .infinity)
            }
        }
        var vis = [Double](repeating: 0, count: m)
        var left = [Double](repeating: 0, count: m), right = [Double](repeating: 0, count: m)
        for a in 0..<m {
            let i = inputs[a]
            vis[a] = i.visible * endRamp(a, count: m)
            let s = CorridorProfile.section(halfWidthCells: i.hw, visible: vis[a],
                                            waterLeft: i.waterLeft, waterRight: i.waterRight,
                                            bend: i.bend, riffle: i.riffle, cellSize: cs,
                                            reachLimit: limits[a], surface: surface(i))
            left[a] = abs(s.offsets[CorridorProfile.topColumn])
            right[a] = abs(s.offsets[CorridorProfile.columns - 1 - CorridorProfile.topColumn])
        }
        left = smoothEdges(left); right = smoothEdges(right)
        var out: [CorridorProfile.Section] = []
        out.reserveCapacity(m)
        for a in 0..<m {
            let i = inputs[a]
            out.append(CorridorProfile.section(halfWidthCells: i.hw, visible: vis[a],
                                               waterLeft: i.waterLeft, waterRight: i.waterRight,
                                               bend: i.bend, riffle: i.riffle, cellSize: cs,
                                               edges: (left[a], right[a]), reachLimit: limits[a],
                                               surface: surface(i)))
        }
        return out
    }

    static func smoothEdges(_ v: [Double]) -> [Double] {
        let m = v.count
        guard m > 2 else { return v }
        var med = v
        var window: [Double] = []
        for a in 0..<m {
            window.removeAll(keepingCapacity: true)
            for b in max(0, a - edgeMedianRadius)...min(m - 1, a + edgeMedianRadius) { window.append(v[b]) }
            window.sort()
            med[a] = window[window.count / 2]
        }
        var out = med
        for a in 0..<m {
            var sum = 0.0, cnt = 0.0
            for b in max(0, a - edgeMeanRadius)...min(m - 1, a + edgeMeanRadius) { sum += med[b]; cnt += 1 }
            out[a] = sum / cnt
        }
        return out
    }
}

struct CorridorBandBuilder {
    struct Sample {
        var x: Double, z: Double
        var tx: Double, tz: Double
        var section: CorridorProfile.Section
        var alpha: Double
        var rank: Double
        var bend: Double
        var arc: Double
    }
    var samples: [Sample] = []

    static let sampleStride = 2

    static func strideIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var out = Array(stride(from: 0, to: count, by: sampleStride))
        if (count - 1) % sampleStride != 0 { out.append(count - 1) }
        return out
    }

    static func meshLids(_ lids: [Double], arc: [Double]) -> [Double] {
        let idx = strideIndices(count: lids.count)
        var out = lids
        guard idx.count >= 2 else { return out }
        for s in 1..<idx.count {
            let a0 = idx[s - 1], a1 = idx[s]
            guard a1 - a0 > 1 else { continue }
            let span = max(arc[a1] - arc[a0], 1e-12)
            for a in (a0 + 1)..<a1 {
                let t = (arc[a] - arc[a0]) / span
                out[a] = lids[a0] + (lids[a1] - lids[a0]) * t
            }
        }
        return out
    }

    func emit(into mesh: inout RiverCorridorMesh, cellSize cs: Double, worldHalf half: Double) {
        let all = samples
        guard all.count >= 2 else { return }
        let samples = Self.strideIndices(count: all.count).map { all[$0] }
        let m = samples.count
        guard m >= 2 else { return }
        let k = CorridorProfile.columns
        let base = mesh.vertices.count
        var pos = [SIMD3<Double>](repeating: .zero, count: m * k)
        for a in 0..<m {
            let s = samples[a]
            for c in 0..<k {
                let off = s.section.offsets[c]
                let gx = s.x - s.tz * off, gz = s.z + s.tx * off
                pos[a * k + c] = SIMD3(gx * cs - half, s.section.heights[c], gz * cs - half)
            }
        }
        for a in 0..<m {
            let s = samples[a]
            let a0 = max(0, a - 1), a1 = min(m - 1, a + 1)
            let edgeL = max(abs(s.section.offsets[0]), 1e-6), edgeR = max(abs(s.section.offsets[k - 1]), 1e-6)
            for c in 0..<k {
                let c0 = max(0, c - 1), c1 = min(k - 1, c + 1)
                let across = pos[a * k + c1] - pos[a * k + c0]
                let along = pos[a1 * k + c] - pos[a0 * k + c]
                var nrm = SIMD3(across.y * along.z - across.z * along.y,
                                across.z * along.x - across.x * along.z,
                                across.x * along.y - across.y * along.x)
                if nrm.y < 0 { nrm = -nrm }
                let len = (nrm * nrm).sum().squareRoot()
                nrm = len > 1e-12 ? nrm / len : SIMD3(0, 1, 0)
                let p = pos[a * k + c]
                mesh.vertices.append(SIMD3(Float(p.x), Float(p.y), Float(p.z)))
                mesh.normals.append(SIMD3(Float(nrm.x), Float(nrm.y), Float(nrm.z)))
                mesh.colors.append(SIMD4(Float(s.tx * 0.5 + 0.5), Float(s.tz * 0.5 + 0.5),
                                         Float(clamp01(s.rank)), Float(clamp01(s.alpha))))
                let off = s.section.offsets[c]
                mesh.uvs.append(SIMD2(Float(max(-1, min(1, off / (off < 0 ? edgeL : edgeR)))), Float(s.arc)))
                mesh.uv2s.append(SIMD2(Float(max(-1, min(1, s.bend))), Float(s.section.bar[c])))
                mesh.custom.append(SIMD4(Float(s.section.depths[c]), Float(s.section.lid),
                                         Float(s.section.offsets[c] * cs),
                                         Float(s.section.waterHalfWidthCells * cs)))
            }
        }
        for a in 1..<m {
            for c in 0..<(k - 1) {
                let v00 = Int32(base + (a - 1) * k + c), v01 = v00 + 1
                let v10 = Int32(base + a * k + c), v11 = v10 + 1
                mesh.indices.append(contentsOf: [v00, v10, v01, v01, v10, v11])
            }
        }
    }
}
