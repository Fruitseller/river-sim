import Foundation
import SimCore

public struct RibbonMesh: Equatable {
    public var vertices: [SIMD3<Float>]
    public var colors: [SIMD4<Float>]
    public var uvs: [SIMD2<Float>]
    public var uv2s: [SIMD2<Float>]
    public var flows: [SIMD4<Float>]
    public var indices: [Int32]
    public var stripStarts: [Int32]
    public var bandChannelFlags: [Bool]
    public var bandCoverage: [Double]
    public var bandOwner: [Int32]
    public var profile: [SIMD4<Float>]
    public var corridor: RiverCorridorMesh

    public init(vertices: [SIMD3<Float>] = [], colors: [SIMD4<Float>] = [],
                uvs: [SIMD2<Float>] = [], uv2s: [SIMD2<Float>] = [],
                flows: [SIMD4<Float>] = [],
                indices: [Int32] = [], stripStarts: [Int32] = [],
                bandChannelFlags: [Bool] = [], bandCoverage: [Double] = [],
                bandOwner: [Int32] = [], profile: [SIMD4<Float>] = [],
                corridor: RiverCorridorMesh = RiverCorridorMesh()) {
        self.profile = profile
        self.corridor = corridor
        self.vertices = vertices
        self.colors = colors
        self.uvs = uvs
        self.uv2s = uv2s
        self.flows = flows
        self.indices = indices
        self.stripStarts = stripStarts
        self.bandChannelFlags = bandChannelFlags
        self.bandCoverage = bandCoverage
        self.bandOwner = bandOwner
    }
}

public final class RiverRibbonRenderer {
    public init() {}

    private var riverSnapshot: [Double]?
    public private(set) var mesh = RibbonMesh()
    public var bandChannelFlags: [Bool] { mesh.bandChannelFlags }

    private var matureCoverage: [Double] = []
    private var previousMatureCoverage: [Double] = []
    private var previousCoverage: [Double] = []
    private var youngYear: [Double] = []
    private var stampOwner: Int32 = -1
    struct CorridorBand { var owner: Int32; var start: Int; var end: Int }
    struct CorridorWater { var owner: Int32; var x: Double; var z: Double; var r: Double }
    private var corridorBands: [CorridorBand] = []
    private var corridorWater: [CorridorWater] = []
    private var corridorBandCount: Int32 = 0
    private var waterOwnerA: [Int32] = []
    private var waterOwnerB: [Int32] = []
    private var owners: [Int32] = []
    private var lastRiverBands: [[RibbonSample]] = []
    private var ghosts: [(bands: [[RibbonSample]], year: Double)] = []
    private var lastBuildYear: Double?
    public private(set) var inTransition = false
    public var ghostCount: Int { ghosts.count }
    public private(set) var growthStats = (young: 0, exempt: 0)
    public var matureCoverageForDiagnostics: [Double] { matureCoverage }

    public func endTransitions(otherWorld: Bool) {
        ghosts = []
        lastRiverBands = []
        lastBuildYear = nil
        inTransition = false
        youngYear = []
        if otherWorld {
            matureCoverage = []
            previousMatureCoverage = []
            previousCoverage = []
        }
    }

    public var bandCoverage: [Double] { mesh.bandCoverage }
    public private(set) var bandVisibleCoverage: [Double] = []
    public var bandOwner: [Int32] { mesh.bandOwner }

    public var renderGrid = 0
    var fadesUphill = true

    private struct RibbonSample {
        var x: Double
        var z: Double
        var halfWidth: Double
        var alpha: Double
        var rank: Double
        var surface: Double?
        var bend: Double = 0
        var seaMouth = false
        var growth = 1.0
    }

    private func flattenedChannelPositions(_ terrain: Terrain) -> [Double] {
        let totalCount = terrain.meander.channels.reduce(0) { $0 + 1 + $1.nodes.count * 2 }
        var flat: [Double] = []
        flat.reserveCapacity(totalCount)
        for ch in terrain.meander.channels {
            flat.append(Double(ch.nodes.count))
            for nd in ch.nodes { flat.append(nd.x); flat.append(nd.z) }
        }
        return flat
    }

    public func maxDelta(_ terrain: Terrain) -> Double {
        guard let snapshot = riverSnapshot else { return Self.rebuildSentinel }
        var idx = 0
        var maxD = 0.0
        for ch in terrain.meander.channels {
            let count = ch.nodes.count
            guard idx < snapshot.count else { return Self.rebuildSentinel }
            if snapshot[idx] != Double(count) { return Self.rebuildSentinel }
            idx += 1
            guard idx + count * 2 <= snapshot.count else { return Self.rebuildSentinel }
            for nd in ch.nodes {
                let dx = abs(nd.x - snapshot[idx])
                let dz = abs(nd.z - snapshot[idx + 1])
                guard dx.isFinite && dz.isFinite else { return Self.rebuildSentinel }
                maxD = max(maxD, max(dx, dz))
                idx += 2
            }
        }
        guard idx == snapshot.count else { return Self.rebuildSentinel }
        return maxD
    }

    static let rebuildSentinel = 1e9

    public func markBuilt(_ terrain: Terrain) { riverSnapshot = flattenedChannelPositions(terrain) }

    public func invalidateSnapshot() { riverSnapshot = nil }

    @discardableResult
    public func build(_ terrain: Terrain, hscale: Double, lift: Double) -> RibbonMesh {
        mesh.vertices.removeAll(keepingCapacity: true)
        mesh.colors.removeAll(keepingCapacity: true)
        mesh.uvs.removeAll(keepingCapacity: true)
        mesh.uv2s.removeAll(keepingCapacity: true)
        mesh.flows.removeAll(keepingCapacity: true)
        mesh.profile.removeAll(keepingCapacity: true)
        mesh.corridor.removeAll()
        corridorBands.removeAll(keepingCapacity: true)
        corridorWater.removeAll(keepingCapacity: true)
        corridorBandCount = 0
        mesh.indices.removeAll(keepingCapacity: true)
        mesh.stripStarts.removeAll(keepingCapacity: true)
        let n = terrain.cfg.n
        mesh.bandChannelFlags = [Bool](repeating: false,
                                       count: terrain.meander.channels.count)
        let cnt = n * n
        guard n > 0, terrain.h.count == cnt,
              terrain.waterLevel.count == cnt,
              terrain.streamMap.count == cnt else {
            mesh.bandCoverage = []
            bandVisibleCoverage = []
            return mesh
        }
        swap(&previousCoverage, &mesh.bandCoverage)
        swap(&owners, &mesh.bandOwner)
        if owners.count != cnt {
            owners = [Int32](repeating: -1, count: cnt)
        } else {
            owners.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress else { return }
                base.update(repeating: -1, count: cnt)
            }
        }
        stampOwner = -1
        if bandVisibleCoverage.count != cnt {
            bandVisibleCoverage = [Double](repeating: 0, count: cnt)
        } else {
            bandVisibleCoverage.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress else { return }
                base.update(repeating: 0, count: cnt)
            }
        }
        if mesh.bandCoverage.count != cnt {
            mesh.bandCoverage = [Double](repeating: 0, count: cnt)
        } else {
            mesh.bandCoverage.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress else { return }
                base.update(repeating: 0, count: cnt)
            }
        }
        let cs = terrain.cfg.cellSize
        guard cs > 0, cs.isFinite else { return mesh }
        let year = terrain.years
        swap(&previousMatureCoverage, &matureCoverage)
        if matureCoverage.count != cnt {
            matureCoverage = [Double](repeating: 0, count: cnt)
        } else {
            matureCoverage.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress else { return }
                base.update(repeating: 0, count: cnt)
            }
        }
        var coupled = -Double.infinity
        if let since = lastBuildYear, year >= since {
            for ch in terrain.meander.channels {
                for b in ch.born where b.isFinite && b >= since { coupled = max(coupled, b) }
            }
            if coupled.isFinite, !lastRiverBands.isEmpty {
                ghosts.append((bands: lastRiverBands, year: coupled))
            }
        } else if lastBuildYear != nil {
            ghosts = []
        }
        lastRiverBands = []
        lastBuildYear = year
        let couplingBuild = coupled.isFinite && previousCoverage.count == cnt
        if youngYear.count != cnt { youngYear = [Double](repeating: -.infinity, count: cnt) }
        var growing = false
        growthStats = (young: 0, exempt: 0)
        let creek = terrain.cfg.renderMinCells
        let smap = terrain.streamMap
        let orders = terrain.strahlerOrders(minCells: terrain.cfg.meanderMinCells)
        guard orders.count == cnt else {
            mesh.bandCoverage = []
            bandVisibleCoverage = []
            return mesh
        }

        let subdivisions = 3
        let channels = terrain.meander.channels
        let peak = channels.map { $0.discharge.max() ?? 0 }
        let order = channels.indices.sorted {
            peak[$0] != peak[$1] ? peak[$0] > peak[$1] : $0 < $1
        }
        var fanMouths: [(x: Double, z: Double)] = []
        for chIndex in order {
            let ch = channels[chIndex]
            let nodes = ch.nodes
            let m = nodes.count
            if m < 2 { continue }
            guard ch.discharge.count >= m, ch.born.isEmpty || ch.born.count >= m else { continue }
            guard !nodes.contains(where: {
                !$0.x.isFinite || !$0.z.isFinite || abs($0.x) > 1e9 || abs($0.z) > 1e9
            }) else { continue }
            guard !ch.discharge.prefix(m).contains(where: { !$0.isFinite || abs($0) > 1e9 }) else { continue }
            let hgridBend = terrain.h
            let nodeBend = MeanderState.bendStrength(ch, config: terrain.cfg,
                                                     heightAt: { bilinearGrid(hgridBend, $0.x, $0.z, n: n) })
            var px: [Double] = [], pz: [Double] = [], pq: [Double] = [], pb: [Double] = []
            var pBorn: [Double] = []
            px.reserveCapacity(m * subdivisions)
            pz.reserveCapacity(m * subdivisions)
            pq.reserveCapacity(m * subdivisions)
            for i in 0..<(m - 1) {
                let p0 = nodes[max(i - 1, 0)], p1 = nodes[i]
                let p2 = nodes[i + 1], p3 = nodes[min(i + 2, m - 1)]
                for s in 0..<subdivisions {
                    let t = Double(s) / Double(subdivisions)
                    let t2 = t * t, t3 = t2 * t
                    px.append(0.5 * (2 * p1.x + (p2.x - p0.x) * t
                        + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                        + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3))
                    pz.append(0.5 * (2 * p1.z + (p2.z - p0.z) * t
                        + (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2
                        + (3 * p1.z - p0.z - 3 * p2.z + p3.z) * t3))
                    pq.append(ch.discharge[i] + (ch.discharge[i + 1] - ch.discharge[i]) * t)
                    pb.append(nodeBend[i] + (nodeBend[i + 1] - nodeBend[i]) * t)
                    let b0 = ch.bornAt(i), b1 = ch.bornAt(i + 1)
                    pBorn.append(b0.isFinite && b1.isFinite ? b0 + (b1 - b0) * t : (t < 0.5 ? b0 : b1))
                }
            }
            px.append(nodes[m - 1].x); pz.append(nodes[m - 1].z); pq.append(ch.discharge[m - 1])
            pb.append(nodeBend[m - 1]); pBorn.append(ch.bornAt(m - 1))
            let cnt = px.count
            var alpha = [Double](repeating: 0, count: cnt)
            var rank = [Double](repeating: 0, count: cnt)
            var supportSum = 0.0, supportWeight = 0.0
            for a in 0..<cnt {
                let ci = min(max(Int(px[a].rounded()), 0), n - 1)
                let cj = min(max(Int(pz[a].rounded()), 0), n - 1)
                var localOrder: Int32 = 0
                for oj in max(0, cj - 1)...min(n - 1, cj + 1) {
                    for oi in max(0, ci - 1)...min(n - 1, ci + 1) {
                        localOrder = max(localOrder, orders[oj * n + oi])
                    }
                }
                let ord = Double(localOrder)
                rank[a] = clamp01(ord / WaterRender.ribbonRankDivisor)
                let stream = bilinearGrid(smap, px[a], pz[a], n: n)
                let mM = WaterRender.corridorMask(streamMap: stream)
                let ramp = smoothstep(0, creek, pq[a])
                var aQ = ramp
                if ord >= 3 { aQ = max(aQ, 0.5) }
                alpha[a] = aQ
                let weight = max(ramp, 0.05)
                supportSum += mM * weight
                supportWeight += weight
            }
            let hgrid = terrain.h
            let slopeWindow = 2
            var cascade = [Double](repeating: 0, count: cnt)
            for a in 0..<cnt {
                let a0 = max(0, a - slopeWindow), a1 = min(cnt - 1, a + slopeWindow)
                let dxs = (px[a1] - px[a0]) * cs, dzs = (pz[a1] - pz[a0]) * cs
                let run = (dxs * dxs + dzs * dzs).squareRoot()
                if run < 1e-9 { continue }
                let drop = bilinearGrid(hgrid, px[a0], pz[a0], n: n)
                         - bilinearGrid(hgrid, px[a1], pz[a1], n: n)
                cascade[a] = WaterRender.cascadeWeight(slope: drop / run)
            }
            let cascadeReach = 4
            for a in 0..<cnt {
                var w = 0.0
                for b in max(0, a - cascadeReach)...min(cnt - 1, a + cascadeReach) {
                    w = max(w, cascade[b])
                }
                alpha[a] *= 1 - w
            }
            let supportMean = supportSum / max(supportWeight, 1e-9)
            let channelOpacity = smoothstep(0, 1, (supportMean - WaterRender.ribbonSupportLo)
                                                  / WaterRender.ribbonSupportSpan)
            for a in 0..<cnt {
                alpha[a] *= max(channelOpacity,
                                WaterRender.ribbonTrust(dischargeCells: pq[a], referenceCells: creek))
            }
            var growth = [Double](repeating: 1, count: cnt)
            let mature = previousMatureCoverage.count == n * n ? previousMatureCoverage : []
            var young = 0, exempt = 0
            youngYear.withUnsafeMutableBufferPointer { yb in
                guard let py = yb.baseAddress else { return }
                for a in 0..<cnt {
                    var g = 1.0
                    if pBorn[a].isFinite {
                        g = WaterRender.ribbonGrowth(ageYears: year - pBorn[a])
                        if g < 1 { young += 1 }
                        if g < 1, !mature.isEmpty, bilinearGrid(mature, px[a], pz[a], n: n) >= 0.5 {
                            g = 1
                            exempt += 1
                        }
                    }
                    let ci = min(max(Int(px[a].rounded()), 0), n - 1)
                    let cj = min(max(Int(pz[a].rounded()), 0), n - 1)
                    if couplingBuild, g >= 1,
                       bilinearGrid(previousCoverage, px[a], pz[a], n: n) < WaterRender.ribbonGrowVisibleCoverage {
                        g = WaterRender.ribbonGrowth(ageYears: year - coupled)
                        young += 1
                        let r = Int((ribbonHalfWidthCells(pq[a], cfg: terrain.cfg) + 1).rounded(.up))
                        for jj in max(0, cj - r)...min(n - 1, cj + r) {
                            for ii in max(0, ci - r)...min(n - 1, ci + r) where py[jj * n + ii] < coupled {
                                py[jj * n + ii] = coupled
                            }
                        }
                    } else if g >= 1, py[cj * n + ci].isFinite {
                        g = WaterRender.ribbonGrowth(ageYears: year - py[cj * n + ci])
                        if g < 1 { young += 1 }
                    }
                    growth[a] = g
                }
            }
            growthStats.young += young
            growthStats.exempt += exempt

            let alphaRadius = 6
            var prefix = [Double](repeating: 0, count: cnt + 1)
            for a in 0..<cnt { prefix[a + 1] = prefix[a] + alpha[a] }
            for a in 0..<cnt {
                let aLo = max(0, a - alphaRadius)
                let aHi = min(cnt, a + alphaRadius + 1)
                alpha[a] = (prefix[aHi] - prefix[aLo]) / Double(aHi - aLo)
            }
            for a in 0..<cnt where growth[a] < 1 { alpha[a] *= growth[a] }
            guard var lo = alpha.firstIndex(where: { $0 > WaterRender.ribbonMinimumAlpha }),
                  var hi = alpha.lastIndex(where: { $0 > WaterRender.ribbonMinimumAlpha })
            else { continue }
            lo = max(0, lo - 2)
            if hi - lo < 2 { continue }
            if !rank[lo...hi].contains(where: { $0 >= WaterRender.ribbonMinimumRank }) { continue }
            for a in 1..<cnt { rank[a] = max(rank[a], rank[a - 1]) }
            mesh.bandChannelFlags[chIndex] = true

            var arc = [Double](repeating: 0, count: cnt)
            for a in (lo + 1)...hi {
                let dx = (px[a] - px[a - 1]) * cs, dz = (pz[a] - pz[a - 1]) * cs
                arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
            }

            var samples: [RibbonSample] = []
            samples.reserveCapacity(hi - lo + 1 + WaterRender.mouthSearchCells)
            let sourceTaperCells = max(WaterRender.ribbonSourceTaperCells,
                                       WaterRender.ribbonLandTaperHalfWidths
                                       * ribbonHalfWidthCells(pq[lo], cfg: terrain.cfg))
            for a in lo...hi {
                let taper = clamp01(arc[a] / (sourceTaperCells * cs))
                let grow = WaterRender.ribbonGrowWidth(growth[a])
                samples.append(RibbonSample(x: px[a], z: pz[a],
                                            halfWidth: ribbonHalfWidthCells(pq[a], cfg: terrain.cfg) * taper * grow,
                                            alpha: alpha[a] * taper,
                                            rank: rank[a], surface: nil, bend: pb[a],
                                            growth: growth[a]))
            }

            if let wet = (lo...hi).first(where: { a in
                let ci = min(max(Int(px[a].rounded()), 0), n - 1)
                let cj = min(max(Int(pz[a].rounded()), 0), n - 1)
                return terrain.h[cj * n + ci] <= terrain.cfg.sea
            }), wet - 1 > lo + 2, wet <= hi,
               rank[lo...(wet - 1)].contains(where: { $0 >= WaterRender.ribbonMinimumRank }) {
                let cut = hi - (wet - 1)
                samples.removeLast(cut)
                hi = wet - 1
            }
            let tail = max(lo, hi - 2)
            let mouth = mouthPath(terrain, fromX: px[hi], fromZ: pz[hi],
                                  dirX: px[hi] - px[tail], dirZ: pz[hi] - pz[tail])
            let join = mouth.isEmpty ? bandJoinPath(fromX: px[hi], fromZ: pz[hi], terrain: terrain) : nil
            if let join {
                if let last = samples.last {
                    var prevX = px[hi], prevZ = pz[hi]
                    for point in join {
                        for mid in [false, true] {
                            var s2 = last
                            s2.x = mid ? point.x : (prevX + point.x) * 0.5
                            s2.z = mid ? point.z : (prevZ + point.z) * 0.5
                            s2.surface = nil
                            samples.append(s2)
                        }
                        prevX = point.x; prevZ = point.z
                    }
                }
            } else if mouth.isEmpty {
                let tailTaperCells = max(WaterRender.ribbonTailTaperCells,
                                         WaterRender.ribbonLandTaperHalfWidths
                                         * ribbonHalfWidthCells(pq[hi], cfg: terrain.cfg))
                for a in samples.indices {
                    let t = clamp01((arc[hi] - arc[lo + a]) / (tailTaperCells * cs))
                    samples[a].halfWidth *= t
                    samples[a].alpha *= t
                }
            } else {
                if let last = samples.indices.last {
                    var first = last
                    while first > 0, arc[hi] - arc[lo + first - 1] <= WaterRender.mouthAlphaHoldCells * cs {
                        first -= 1
                    }
                    if first < last {
                        for a in (first + 1)...last { samples[a].alpha = max(samples[a].alpha, samples[a - 1].alpha) }
                    }
                }
                let mouthWidth = ribbonHalfWidthCells(pq[hi], cfg: terrain.cfg)
                    * WaterRender.ribbonGrowWidth(growth[hi])
                let mouthAlpha = max(alpha[hi], samples.last?.alpha ?? 0)
                var prevX = px[hi], prevZ = pz[hi]
                let mouthBend = pb[hi], links = Double(mouth.count)
                for (link, point) in mouth.enumerated() {
                    let step = Double(link)
                    samples.append(RibbonSample(x: (prevX + point.x) * 0.5,
                                                z: (prevZ + point.z) * 0.5,
                                                halfWidth: mouthWidth,
                                                alpha: mouthAlpha,
                                                rank: rank[hi], surface: nil,
                                                bend: mouthBend * (1 - (step + 0.5) / links),
                                                growth: growth[hi]))
                    samples.append(RibbonSample(x: point.x, z: point.z,
                                                halfWidth: mouthWidth,
                                                alpha: mouthAlpha,
                                                rank: rank[hi], surface: point.surface,
                                                bend: mouthBend * (1 - (step + 1) / links),
                                                growth: growth[hi]))
                    prevX = point.x
                    prevZ = point.z
                }
                let junction = hi - lo + 1
                let first = max(1, junction - WaterRender.mouthJunctionSmoothSamples)
                let last = samples.count - 2
                if last > first {
                    func pinched() -> Bool {
                        for a in first...last where samples[a].halfWidth > 0 {
                            let r = RiverRibbonRenderer.curvatureRadiusCells(samples[a - 1], samples[a], samples[a + 1])
                                * WaterRender.ribbonCurvatureWidthFactor
                            if r < 0.5 * samples[a].halfWidth { return true }
                        }
                        return false
                    }
                    var pass = 0
                    while pass < 3 || (pass < WaterRender.mouthJunctionMaxSmoothPasses && pinched()) {
                        let raw = samples
                        for a in first...last {
                            samples[a].x = 0.5 * raw[a].x + 0.25 * (raw[a - 1].x + raw[a + 1].x)
                            samples[a].z = 0.5 * raw[a].z + 0.25 * (raw[a - 1].z + raw[a + 1].z)
                        }
                        pass += 1
                    }
                }
                for a in junction..<samples.count {
                    let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
                    let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
                    samples[a].seaMouth = terrain.h[cj * n + ci] <= terrain.cfg.sea
                }
                var taper = WaterRender.ribbonTailTaperCells
                if let firstSea = samples.indices.first(where: { a in
                    guard a >= junction else { return false }
                    let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
                    let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
                    return terrain.h[cj * n + ci] <= terrain.cfg.sea
                }) {
                    var wet = 0.0
                    for a in (firstSea + 1)..<max(firstSea + 1, samples.count) {
                        let dx = samples[a].x - samples[a - 1].x, dz = samples[a].z - samples[a - 1].z
                        wet += (dx * dx + dz * dz).squareRoot()
                    }
                    taper = min(taper, max(wet, 1e-6))
                }
                RiverRibbonRenderer.taperTail(&samples, cells: taper)
            }

            applyWaterHandover(&samples, terrain)
            if fadesUphill { fadeUphill(&samples, terrain) }
            RiverRibbonRenderer.limitAlphaSteps(&samples)
            lastRiverBands.append(samples)
            if samples.contains(where: { $0.growth < 1 }) { growing = true }
            stampOwner = Int32(chIndex)
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindRiver, still: false,
                       hscale: hscale, lift: lift)
            stampOwner = -1

            if let mouthIndex = samples.firstIndex(where: { $0.surface != nil }),
               mouthIndex > 0,
               !fanMouths.contains(where: {
                   let dx = $0.x - samples[mouthIndex].x, dz = $0.z - samples[mouthIndex].z
                   return dx * dx + dz * dz < WaterRender.deltaFanSpacingCells * WaterRender.deltaFanSpacingCells
               }) {
                let entry = samples[mouthIndex], before = samples[mouthIndex - 1]
                fanMouths.append((x: entry.x, z: entry.z))
                var dx = entry.x - before.x, dz = entry.z - before.z
                let dl = (dx * dx + dz * dz).squareRoot()
                if dl > 1e-9 {
                    dx /= dl; dz /= dl
                    appendDeltaArms(terrain, mouthX: entry.x, mouthZ: entry.z, dirX: dx, dirZ: dz,
                                    halfWidth: entry.halfWidth, rank: entry.rank,
                                    hscale: hscale, lift: lift)
                }
            }
        }

        appendOxbowRibbons(terrain, hscale: hscale, lift: lift)

        ghosts.removeAll { WaterRender.ribbonGhostFade(ageYears: year - $0.year) <= 1e-3 }
        for ghost in ghosts {
            let fade = WaterRender.ribbonGhostFade(ageYears: year - ghost.year)
            for band in ghost.bands {
                var visible = [Bool](repeating: false, count: band.count)
                for a in band.indices {
                    let occ = bilinearGrid(mesh.bandCoverage, band[a].x, band[a].z, n: n)
                    let alpha = band[a].alpha * fade * (1 - smoothstep(WaterRender.ribbonOcclusionLo,
                                                                       WaterRender.ribbonOcclusionHi, occ))
                    visible[a] = alpha > WaterRender.ribbonMinimumAlpha
                }
                var a = 0
                while a < band.count {
                    guard visible[a] else { a += 1; continue }
                    var b = a
                    while b + 1 < band.count && visible[b + 1] { b += 1 }
                    let lo = max(0, a - 2), hi = min(band.count - 1, b + 2)
                    if hi - lo >= 2 {
                        var faded = Array(band[lo...hi])
                        for c in faded.indices {
                            faded[c].alpha *= fade
                            faded[c].growth = 0
                        }
                        emitRibbon(faded, terrain, kind: WaterRender.ribbonKindRiver, still: false,
                                   hscale: hscale, lift: lift)
                    }
                    a = b + 1
                }
            }
        }
        inTransition = growing || !ghosts.isEmpty
        fadeCorridorsInForeignWater(n: n, cellSize: terrain.cfg.cellSize, worldHalf: terrain.cfg.world / 2)
        swap(&mesh.bandOwner, &owners)
        return mesh
    }

    static func erodeAndSmooth(_ values: [Double], radius: Int) -> [Double] {
        let cnt = values.count
        guard cnt > 1, radius > 0 else { return values }
        var eroded = values
        for a in 0..<cnt {
            var v = values[a]
            for b in max(0, a - radius)...min(cnt - 1, a + radius) { v = min(v, values[b]) }
            eroded[a] = v
        }
        return boxMean(eroded, radius: radius)
    }

    static let corridorRampSamples = 4
    static func corridorPresence(_ onLand: [Bool], on: Bool) -> [Double] {
        let m = onLand.count
        guard on else { return [Double](repeating: 0, count: m) }
        var dist = [Int](repeating: Int.max / 2, count: m)
        var last = Int.min / 2
        for a in 0..<m {
            if !onLand[a] { last = a }
            dist[a] = a - last
        }
        last = Int.max / 2
        for a in stride(from: m - 1, through: 0, by: -1) {
            if !onLand[a] { last = a }
            dist[a] = min(dist[a], last - a)
        }
        return dist.map { smoothstep(0, Double(corridorRampSamples), Double($0)) }
    }

    private static func boxMean(_ values: [Double], radius: Int) -> [Double] {
        let cnt = values.count
        var prefix = [Double](repeating: 0, count: cnt + 1)
        for a in 0..<cnt { prefix[a + 1] = prefix[a] + values[a] }
        var out = values
        for a in 0..<cnt {
            let aLo = max(0, a - radius), aHi = min(cnt, a + radius + 1)
            out[a] = (prefix[aHi] - prefix[aLo]) / Double(aHi - aLo)
        }
        return out
    }

    private static func taperTail(_ samples: inout [RibbonSample], cells: Double) {
        guard samples.count >= 2, cells > 0 else { return }
        var distance = 0.0
        for a in stride(from: samples.count - 1, through: 0, by: -1) {
            if a < samples.count - 1 {
                let dx = samples[a + 1].x - samples[a].x
                let dz = samples[a + 1].z - samples[a].z
                distance += (dx * dx + dz * dz).squareRoot()
            }
            let t = clamp01(distance / cells)
            samples[a].alpha *= t
            if t >= 1 { break }
        }
    }

    @inline(__always)
    private static func lakeHandoverFade(pond: Double) -> Double {
        1 - smoothstep(WaterRender.pondContourLo, WaterRender.deltaFrontDepth, pond)
    }

    @inline(__always)
    private static func seaHandoverFade(submergedCells: Double) -> Double {
        1 - smoothstep(0.0, WaterRender.mouthOverlapCells, submergedCells)
    }

    private func applyWaterHandover(_ samples: inout [RibbonSample], _ terrain: Terrain) {
        let n = terrain.cfg.n
        let h = terrain.h, wl = terrain.waterLevel
        let sea = terrain.cfg.sea
        var submergedCells = 0.0
        var fade = [Double](repeating: 1, count: samples.count)
        for a in samples.indices {
            let ci = min(max(Int(samples[a].x.rounded()), 0), n - 1)
            let cj = min(max(Int(samples[a].z.rounded()), 0), n - 1)
            let k = cj * n + ci
            let wlS = bilinearGrid(wl, samples[a].x, samples[a].z, n: n)
            let lakePond = wlS > sea
                ? max(wlS - bilinearGrid(h, samples[a].x, samples[a].z, n: n), 0) : 0
            guard let surface = openWaterSurface(k, h: h, wl: wl, sea: sea) else {
                submergedCells = 0
                samples[a].surface = nil
                fade[a] = RiverRibbonRenderer.lakeHandoverFade(pond: lakePond)
                continue
            }
            if a > 0 {
                let dx = samples[a].x - samples[a - 1].x, dz = samples[a].z - samples[a - 1].z
                submergedCells += (dx * dx + dz * dz).squareRoot()
            }
            samples[a].surface = surface
            fade[a] = surface <= sea
                ? RiverRibbonRenderer.seaHandoverFade(submergedCells: submergedCells)
                : RiverRibbonRenderer.lakeHandoverFade(pond: lakePond)
        }
        var lakeFade = fade
        for a in samples.indices {
            let s = samples[a].surface ?? 1.0
            if s <= sea { lakeFade[a] = 1.0 }
        }
        lakeFade = RiverRibbonRenderer.erodeAndSmooth(lakeFade, radius: WaterRender.ribbonHandoverSmoothSamples)
        for a in samples.indices {
            let s = samples[a].surface ?? 1.0
            let f = s <= sea ? fade[a] : lakeFade[a]
            samples[a].alpha *= f
        }
    }

    private func fadeUphill(_ samples: inout [RibbonSample], _ terrain: Terrain) {
        let n = terrain.cfg.n, h = terrain.h
        var lowest = Double.infinity
        for a in samples.indices {
            let y = samples[a].surface
                ?? renderSurfaceHeight(h, samples[a].x, samples[a].z, n: n, renderGrid: renderGrid)
            if y > lowest { samples[a].alpha *= WaterRender.ribbonUphillFade(rise: y - lowest) }
            lowest = min(lowest, y)
        }
    }

    private static func limitAlphaSteps(_ samples: inout [RibbonSample]) {
        guard samples.count >= 2 else { return }
        let step = WaterRender.ribbonMaxAlphaStep
        for a in 1..<samples.count {
            samples[a].alpha = min(samples[a].alpha, samples[a - 1].alpha + step)
        }
        for a in stride(from: samples.count - 2, through: 0, by: -1) {
            samples[a].alpha = min(samples[a].alpha, samples[a + 1].alpha + step)
        }
    }

    private func bandJoinPath(fromX: Double, fromZ: Double, terrain: Terrain) -> [(x: Double, z: Double)]? {
        RiverRibbonRenderer.joinPath(fromX: fromX, fromZ: fromZ, coverage: mesh.bandCoverage, terrain: terrain)
    }

    static func joinPath(fromX: Double, fromZ: Double, coverage cover: [Double],
                         terrain: Terrain) -> [(x: Double, z: Double)]? {
        let n = terrain.cfg.n, cnt = n * n
        guard fromX.isFinite, fromZ.isFinite, cover.count == cnt,
              terrain.receiver.count == cnt, terrain.h.count == cnt else { return nil }
        var k = min(max(Int(fromZ.rounded()), 0), n - 1) * n + min(max(Int(fromX.rounded()), 0), n - 1)
        if cover[k] >= WaterRender.ribbonJoinCoverage { return [] }
        var path: [(x: Double, z: Double)] = []
        for _ in 0..<WaterRender.ribbonJoinSearchCells {
            let r = Int(terrain.receiver[k])
            guard r >= 0, r < cnt, terrain.h[r] > terrain.cfg.sea else { return nil }
            k = r
            path.append((Double(k % n), Double(k / n)))
            if cover[k] >= WaterRender.ribbonJoinCoverage { return path }
        }
        return nil
    }

    private func emitRibbon(_ samples: [RibbonSample], _ terrain: Terrain,
                            kind: Double, still: Bool,
                            hscale: Double, lift: Double) {
        guard samples.count >= 2, terrain.cfg.cellSize > 0 else { return }
        let n = terrain.cfg.n
        let cs = terrain.cfg.cellSize
        let half = terrain.cfg.world / 2
        let h = terrain.h
        let originalSamples = samples
        var samples = samples
        var occludedMature: [Int] = []
        var occlusion = [Double](repeating: 0, count: samples.count)
        for a in samples.indices {
            let occ = bilinearGrid(mesh.bandCoverage, samples[a].x, samples[a].z, n: n)
            occlusion[a] = occ
            let before = samples[a].alpha
            samples[a].alpha *= 1 - smoothstep(WaterRender.ribbonOcclusionLo,
                                               WaterRender.ribbonOcclusionHi, occ)
            if samples[a].growth >= 1, before > WaterRender.ribbonMinimumAlpha,
               samples[a].alpha <= WaterRender.ribbonMinimumAlpha {
                occludedMature.append(a)
            }
        }
        if !occludedMature.isEmpty, matureCoverage.count == n * n {
            matureCoverage.withUnsafeMutableBufferPointer { mb in
                guard let pm = mb.baseAddress else { return }
                for a in occludedMature {
                    let r = max(0, samples[a].halfWidth) + 0.5
                    let ci = samples[a].x, cj = samples[a].z
                    let i0 = max(0, Int((ci - r).rounded(.down))), i1 = min(n - 1, Int((ci + r).rounded(.up)))
                    let j0 = max(0, Int((cj - r).rounded(.down))), j1 = min(n - 1, Int((cj + r).rounded(.up)))
                    guard i0 <= i1, j0 <= j1 else { continue }
                    for j in j0...j1 {
                        for i in i0...i1 {
                            let dx = Double(i) - ci, dz = Double(j) - cj
                            if dx * dx + dz * dz <= r * r { pm[j * n + i] = 1 }
                        }
                    }
                }
            }
        }
        RiverRibbonRenderer.limitAlphaSteps(&samples)
        var arc = [Double](repeating: 0, count: samples.count)
        for a in 1..<samples.count {
            let dx = (samples[a].x - samples[a - 1].x) * cs
            let dz = (samples[a].z - samples[a - 1].z) * cs
            arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
        }
        var halfWidthCells = [Double](repeating: 0, count: samples.count)
        for a in 0..<samples.count {
            let maxRadius = RiverRibbonRenderer.curvatureRadiusCells(
                                samples[max(0, a - 1)], samples[a],
                                samples[min(samples.count - 1, a + 1)])
                            * WaterRender.ribbonCurvatureWidthFactor
            halfWidthCells[a] = min(maxRadius, max(0, samples[a].halfWidth))
        }
        let widthSlope = WaterRender.ribbonMaxHalfWidthSlope
        for a in 1..<samples.count {
            let len = (arc[a] - arc[a - 1]) / cs
            halfWidthCells[a] = min(halfWidthCells[a], halfWidthCells[a - 1] + widthSlope * len)
        }
        for a in stride(from: samples.count - 2, through: 0, by: -1) {
            let len = (arc[a + 1] - arc[a]) / cs
            halfWidthCells[a] = min(halfWidthCells[a], halfWidthCells[a + 1] + widthSlope * len)
        }
        let flows = RiverRibbonRenderer.flowAttributes(
            samples, halfWidthCells: halfWidthCells, arc: arc, occlusion: occlusion,
            cellSize: cs, flowing: !still && kind == WaterRender.ribbonKindRiver,
            height: { bilinearGrid(h, $0, $1, n: n) })
        let base = mesh.vertices.count
        mesh.stripStarts.append(Int32(base))
        let corridorOn = kind == WaterRender.ribbonKindRiver && !still
        let presence = RiverRibbonRenderer.corridorPresence(samples.map { $0.surface == nil }, on: corridorOn)
        let bank = BankSurface(h: h, n: n, renderGrid: renderGrid, hscale: hscale)
        var corridor = CorridorBandBuilder()
        var corridorInputs: [CorridorSections.Input] = []
        let profileBase = mesh.profile.count
        var previous: (x: Double, z: Double, halfWidthCells: Double, alpha: Double)?
        for a in 0..<samples.count {
            let s = samples[a]
            let a0 = max(0, a - 1), a1 = min(samples.count - 1, a + 1)
            var tx = samples[a1].x - samples[a0].x, tz = samples[a1].z - samples[a0].z
            var tl = (tx * tx + tz * tz).squareRoot()
            if tl <= 1e-6 {
                tx = samples[a1].x - samples[a].x; tz = samples[a1].z - samples[a].z
                tl = (tx * tx + tz * tz).squareRoot()
            }
            if tl <= 1e-6 {
                tx = samples[a].x - samples[a0].x; tz = samples[a].z - samples[a0].z
                tl = (tx * tx + tz * tz).squareRoot()
            }
            if tl > 1e-6 { tx /= tl; tz /= tl } else { tx = 1; tz = 0 }
            let hwCells = halfWidthCells[a]
            let hw = hwCells * cs
            let wx = s.x * cs - half, wz = s.z * cs - half
            let perpx = -tz * hw, perpz = tx * hw
            let edgeGX = perpx / cs, edgeGZ = perpz / cs
            let yCenter = renderSurfaceHeight(h, s.x, s.z, n: n,
                                              renderGrid: renderGrid) * hscale
            let crossTol = hw * WaterRender.ribbonMaxCrossSlope
            let yL = renderSurfaceHeight(h, s.x - edgeGX, s.z - edgeGZ, n: n,
                                         renderGrid: renderGrid) * hscale
            let yR = renderSurfaceHeight(h, s.x + edgeGX, s.z + edgeGZ, n: n,
                                         renderGrid: renderGrid) * hscale
            let level = yCenter + lift
            let reach = max(WaterRender.ribbonWaterlineReachMin,
                            WaterRender.ribbonWaterlineReach * WaterRender.ribbonVisibleWidth(s.alpha))
            let wlLift = WaterRender.ribbonWaterlineLift
            var gL = Double.infinity, gR = Double.infinity
            for f in [WaterRender.ribbonWaterlineInner, 0.5 * (1 + WaterRender.ribbonWaterlineInner), 1.0] {
                let r = reach * f
                gL = min(gL, renderSurfaceHeight(h, s.x - edgeGX * r, s.z - edgeGZ * r, n: n,
                                                 renderGrid: renderGrid) * hscale)
                gR = min(gR, renderSurfaceHeight(h, s.x + edgeGX * r, s.z + edgeGZ * r, n: n,
                                                 renderGrid: renderGrid) * hscale)
            }
            var wL = min(level, gL + wlLift), wR = min(level, gR + wlLift)
            do {
                let mid0 = (wL + wR) * 0.5, k0 = (wR - wL) / (2 * reach)
                var need = 0.0
                for f in [-0.6, -0.3, 0.0, 0.3, 0.6] {
                    let r = reach * f
                    let g = renderSurfaceHeight(h, s.x + edgeGX * r, s.z + edgeGZ * r, n: n,
                                                renderGrid: renderGrid) * hscale
                    need = max(need, g + WaterRender.ribbonCenterClearance - (mid0 + k0 * r))
                }
                let raise = max(0, min(need, WaterRender.ribbonCenterRaiseMax, level - max(wL, wR)))
                wL += raise; wR += raise
            }
            let mid = (wL + wR) * 0.5, k = (wR - wL) / (2 * reach)
            let yMax = yCenter + crossTol + lift
            var yLeftD = min(yMax, mid - k, max(wL, yL + wlLift))
            var yRightD = min(yMax, mid + k, max(wR, yR + wlLift))
            if let surface = s.surface {
                let onSea = surface <= terrain.cfg.sea + 1e-9
                let y = surface * hscale + (onSea ? WaterRender.ribbonSeaSurfaceSink
                                                  : WaterRender.ribbonLakeSurfaceLift)
                let mouthUnder = s.seaMouth && yCenter <= terrain.cfg.sea * hscale
                if onSea && (kind == WaterRender.ribbonKindDelta || mouthUnder) {
                    yLeftD = y; yRightD = y
                } else if onSea {
                    yLeftD = max(yLeftD, y)
                    yRightD = max(yRightD, y)
                } else {
                    let w = smoothstep(WaterRender.geometryLiftLo, WaterRender.geometryLiftHi,
                                       surface - yCenter / hscale)
                    yLeftD += w * max(0, y - yLeftD)
                    yRightD += w * max(0, y - yRightD)
                }
            }
            let yLeft = Float(yLeftD), yRight = Float(yRightD)
            if corridorOn {
                corridorInputs.append(.init(hw: hwCells,
                                            visible: WaterRender.ribbonVisibleWidth(s.alpha * presence[a]),
                                            waterLeft: yLeftD, waterRight: yRightD,
                                            bend: s.bend, riffle: Double(flows[a].x),
                                            x: s.x, z: s.z, tx: tx, tz: tz))
                mesh.profile.append(.zero); mesh.profile.append(.zero)
            } else {
                for own in [yLeft, yRight] {
                    mesh.profile.append(SIMD4<Float>(0, own, Float(hwCells * cs), 0))
                }
            }
            if let p = previous {
                stampCoverage(fromX: p.x, fromZ: p.z,
                              fromHalfWidthCells: p.halfWidthCells, fromAlpha: p.alpha,
                              toX: s.x, toZ: s.z,
                              toHalfWidthCells: hwCells, toAlpha: s.alpha,
                              openStart: a == 1, openEnd: a == samples.count - 1,
                              mature: min(samples[a - 1].growth, s.growth) >= 1,
                              n: n)
            }
            previous = (x: s.x, z: s.z, halfWidthCells: hwCells, alpha: s.alpha)
            mesh.vertices.append(SIMD3(Float(wx - perpx), yLeft, Float(wz - perpz)))
            mesh.vertices.append(SIMD3(Float(wx + perpx), yRight, Float(wz + perpz)))
            let dirX = still ? 0.0 : tx, dirZ = still ? 0.0 : tz
            let col = SIMD4(Float(dirX * 0.5 + 0.5), Float(dirZ * 0.5 + 0.5),
                            Float(clamp01(s.rank)),
                            Float(clamp01(s.alpha)))
            mesh.colors.append(col); mesh.colors.append(col)
            mesh.uvs.append(SIMD2(0, Float(arc[a])))
            mesh.uvs.append(SIMD2(1, Float(arc[a])))
            let kindUV = SIMD2(Float(kind), Float(max(-1, min(1, s.bend))))
            mesh.uv2s.append(kindUV); mesh.uv2s.append(kindUV)
            mesh.flows.append(flows[a]); mesh.flows.append(flows[a])
            if a > 0 {
                let v = Int32(base + (a - 1) * 2)
                mesh.indices.append(v); mesh.indices.append(v + 2); mesh.indices.append(v + 1)
                mesh.indices.append(v + 1); mesh.indices.append(v + 2); mesh.indices.append(v + 3)
            }
        }
        if corridorOn {
            let sections = CorridorSections.build(corridorInputs, cellSize: cs, bank: bank)
            let lids = CorridorBandBuilder.meshLids(sections.map(\.lid), arc: arc)
            for a in 0..<sections.count {
                let section = sections[a], inp = corridorInputs[a], pres = presence[a]
                corridor.samples.append(.init(x: inp.x, z: inp.z, tx: inp.tx, tz: inp.tz, section: section,
                                              alpha: samples[a].alpha * pres, rank: samples[a].rank,
                                              bend: samples[a].bend, arc: arc[a]))
                let half = Float(inp.hw * max(0, min(1, inp.visible)) * cs)
                let lidShare = min(1, pres / CorridorSections.lidPresence)
                for (k, own) in [inp.waterLeft, inp.waterRight].enumerated() {
                    mesh.profile[profileBase + 2 * a + k] =
                        SIMD4(Float(pres), Float(own + lidShare * max(0, lids[a] - own)), half, 0)
                }
            }
            let start = mesh.corridor.vertices.count
            corridor.emit(into: &mesh.corridor, cellSize: cs, worldHalf: half)
            corridorBands.append(.init(owner: corridorBandCount, start: start,
                                       end: mesh.corridor.vertices.count))
            for a in 0..<min(originalSamples.count, halfWidthCells.count) {
                let r = halfWidthCells[a] * WaterRender.ribbonVisibleWidth(originalSamples[a].alpha)
                    * CorridorProfile.shoreFraction
                guard r > 0 else { continue }
                corridorWater.append(.init(owner: corridorBandCount, x: originalSamples[a].x,
                                           z: originalSamples[a].z, r: r))
            }
            corridorBandCount += 1
        }
    }

    private func fadeCorridorsInForeignWater(n: Int, cellSize cs: Double, worldHalf half: Double) {
        guard corridorBandCount > 1, cs > 0 else { return }
        let cnt = n * n
        if waterOwnerA.count != cnt {
            waterOwnerA = [Int32](repeating: -1, count: cnt)
            waterOwnerB = [Int32](repeating: -1, count: cnt)
        } else {
            for k in 0..<cnt { waterOwnerA[k] = -1; waterOwnerB[k] = -1 }
        }
        for w in corridorWater {
            let i0 = max(0, Int((w.x - w.r).rounded(.down))), i1 = min(n - 1, Int((w.x + w.r).rounded(.up)))
            let j0 = max(0, Int((w.z - w.r).rounded(.down))), j1 = min(n - 1, Int((w.z + w.r).rounded(.up)))
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let dx = Double(i) - w.x, dz = Double(j) - w.z
                    guard dx * dx + dz * dz <= w.r * w.r else { continue }
                    let k = j * n + i
                    if waterOwnerA[k] < 0 { waterOwnerA[k] = w.owner }
                    else if waterOwnerA[k] != w.owner && waterOwnerB[k] < 0 { waterOwnerB[k] = w.owner }
                }
            }
        }
        var gone = [Bool](repeating: false, count: mesh.corridor.vertices.count)
        var anyGone = false
        for band in corridorBands where band.end > band.start {
            for v in band.start..<band.end {
                let p = mesh.corridor.vertices[v]
                let i = Int(((Double(p.x) + half) / cs).rounded()), j = Int(((Double(p.z) + half) / cs).rounded())
                guard i >= 0, i < n, j >= 0, j < n else { continue }
                let a = waterOwnerA[j * n + i], b = waterOwnerB[j * n + i]
                let own = a == band.owner || b == band.owner
                let earlier = a >= 0 && a < band.owner
                let foreign = (a >= 0 && a != band.owner) || (b >= 0 && b != band.owner)
                let dry = mesh.corridor.custom[v].x <= 0
                if earlier || (foreign && !own && dry) {
                    mesh.corridor.colors[v].w = 0
                    gone[v] = true
                    anyGone = true
                }
            }
        }
        guard anyGone else { return }
        var kept: [Int32] = []
        kept.reserveCapacity(mesh.corridor.indices.count)
        let idx = mesh.corridor.indices
        for t in stride(from: 0, to: idx.count - 2, by: 3)
        where !gone[Int(idx[t])] && !gone[Int(idx[t + 1])] && !gone[Int(idx[t + 2])] {
            kept.append(idx[t]); kept.append(idx[t + 1]); kept.append(idx[t + 2])
        }
        mesh.corridor.indices = kept
    }

    private static func flowAttributes(_ samples: [RibbonSample], halfWidthCells: [Double],
                               arc: [Double], occlusion: [Double], cellSize cs: Double,
                               flowing: Bool,
                               height: (Double, Double) -> Double) -> [SIMD4<Float>] {
        let m = samples.count
        var out = [SIMD4<Float>](repeating: .zero, count: m)
        guard m > 0 else { return out }
        for a in 0..<m { out[a].w = Float(2 * halfWidthCells[a] * cs) }
        guard flowing, m >= 2 else { return out }
        let hs = samples.map { height($0.x, $0.z) }
        func window(_ a: Int, _ reach: Double) -> (lo: Int, hi: Int) {
            var lo = a, hi = a
            while lo > 0, arc[a] - arc[lo - 1] <= reach { lo -= 1 }
            while hi < m - 1, arc[hi + 1] - arc[a] <= reach { hi += 1 }
            return (lo, hi)
        }
        let slopeReach = WaterRender.ribbonSlopeWindowCells * cs
        var phase = 0.0
        for a in 0..<m {
            let hw = halfWidthCells[a]
            let width = max(2 * hw, WaterRender.ribbonRiffleMinWidthCells) * cs
            let (lo, hi) = window(a, slopeReach)
            let run = (arc[hi] - arc[lo]) / cs
            let slope = run > 1e-6 ? abs(hs[lo] - hs[hi]) / run : 0
            let steep = smoothstep(WaterRender.ribbonSlopeLo, WaterRender.ribbonSlopeHi, slope)
            let bendAbs = abs(samples[a].bend)
            let riffleBend = 1 - smoothstep(WaterRender.ribbonRiffleBendLo,
                                            WaterRender.ribbonRiffleBendHi, bendAbs)
            let spacing = WaterRender.ribbonRiffleSpacingWidths * width
            if a > 0 { phase += (arc[a] - arc[a - 1]) / spacing }
            let (blo, bhi) = window(a, 0.5 * spacing)
            var bendNear = 0.0
            for b in blo...bhi { bendNear = max(bendNear, abs(samples[b].bend)) }
            let bendy = smoothstep(WaterRender.ribbonRiffleBendLo,
                                   WaterRender.ribbonRiffleBendHi, bendNear)
            let alternation = 0.5 + 0.5 * sin(2 * Double.pi * phase)
            var riffle = bendy * riffleBend + (1 - bendy) * alternation
            riffle += (1 - riffle) * steep * WaterRender.ribbonRiffleSteepShare
            let white = smoothstep(WaterRender.ribbonWhiteSlopeLo, WaterRender.ribbonWhiteSlopeHi, slope)
            let (ulo, _) = window(a, 2 * width)
            var upstream = 0.0
            for b in ulo...a { upstream += halfWidthCells[b] }
            upstream /= Double(a - ulo + 1)
            let narrowing = upstream > 1e-6 ? max(0, (upstream - hw) / upstream) : 0
            let constriction = smoothstep(WaterRender.ribbonConstrictionLo,
                                          WaterRender.ribbonConstrictionHi, narrowing)
            let confluence = smoothstep(WaterRender.ribbonConfluenceLo,
                                        WaterRender.ribbonConfluenceHi, occlusion[a])
            let whitewater = max(white, max(constriction, confluence) * WaterRender.ribbonWhiteRiffleShare,
                                 riffle * steep * WaterRender.ribbonWhiteRiffleShare)
            out[a].x = Float(clamp01(riffle))
            out[a].y = Float(clamp01(whitewater))
            out[a].z = Float(steep)
        }
        return out
    }

    private static func curvatureRadiusCells(_ a: RibbonSample, _ b: RibbonSample,
                                             _ c: RibbonSample) -> Double {
        let abx = b.x - a.x, abz = b.z - a.z
        let bcx = c.x - b.x, bcz = c.z - b.z
        let cax = a.x - c.x, caz = a.z - c.z
        let ab = (abx * abx + abz * abz).squareRoot()
        let bc = (bcx * bcx + bcz * bcz).squareRoot()
        let ca = (cax * cax + caz * caz).squareRoot()
        let cross = abs(abx * bcz - abz * bcx)
        guard cross > 1e-9 else { return .infinity }
        return ab * bc * ca / (2 * cross)
    }

    private func stampCoverage(fromX: Double, fromZ: Double,
                               fromHalfWidthCells: Double, fromAlpha: Double,
                               toX: Double, toZ: Double,
                               toHalfWidthCells: Double, toAlpha: Double,
                               openStart: Bool, openEnd: Bool,
                               mature: Bool = false,
                               n: Int) {
        guard fromAlpha > 0 || toAlpha > 0 else { return }
        let hw0 = max(0, fromHalfWidthCells), hw1 = max(0, toHalfWidthCells)
        let reach = max(hw0, hw1) + 0.5
        let i0 = max(0, Int((min(fromX, toX) - reach).rounded(.down)))
        let i1 = min(n - 1, Int((max(fromX, toX) + reach).rounded(.up)))
        let j0 = max(0, Int((min(fromZ, toZ) - reach).rounded(.down)))
        let j1 = min(n - 1, Int((max(fromZ, toZ) + reach).rounded(.up)))
        guard i0 <= i1, j0 <= j1 else { return }
        let dx = toX - fromX, dz = toZ - fromZ
        let len2 = dx * dx + dz * dz
        let overhang = len2 > 1e-12 ? 0.5 / len2.squareRoot() : 0
        let stampMature = mature && matureCoverage.count == n * n
        let owner = stampOwner
        let hasVisible = bandVisibleCoverage.count == n * n
        mesh.bandCoverage.withUnsafeMutableBufferPointer { cb in
        owners.withUnsafeMutableBufferPointer { ob in
        matureCoverage.withUnsafeMutableBufferPointer { mb in
        bandVisibleCoverage.withUnsafeMutableBufferPointer { vb in
            guard let pc = cb.baseAddress, let po = ob.baseAddress else { return }
            let pm = mb.baseAddress
            let pv = hasVisible ? vb.baseAddress : nil
            for j in j0...j1 {
                for i in i0...i1 {
                    let px = Double(i) - fromX, pz = Double(j) - fromZ
                    let tRaw = len2 > 1e-12 ? (px * dx + pz * dz) / len2 : 0
                    if openStart && tRaw < -overhang { continue }
                    if openEnd && tRaw > 1 + overhang { continue }
                    let t = clamp01(tRaw)
                    let ex = px - dx * t, ez = pz - dz * t
                    let hwRaw = hw0 + (hw1 - hw0) * t
                    let hw = hwRaw + 0.5
                    let e2 = ex * ex + ez * ez
                    if e2 > hw * hw { continue }
                    let value = clamp01(fromAlpha + (toAlpha - fromAlpha) * t)
                    let k = j * n + i
                    if pc[k] < value { pc[k] = value; po[k] = owner }
                    if let pv, pv[k] < value {
                        let hv = max(hwRaw * WaterRender.ribbonVisibleWidth(value)
                                     * WaterRender.ribbonWaterlineReach, 0.5)
                        if e2 <= hv * hv { pv[k] = value }
                    }
                    if stampMature, value > 0 { pm![k] = 1 }
                }
            }
        }}}}
    }

    private func appendDeltaArms(_ terrain: Terrain,
                                 mouthX: Double, mouthZ: Double, dirX: Double, dirZ: Double,
                                 halfWidth: Double, rank: Double,
                                 hscale: Double, lift: Double) {
        let n = terrain.cfg.n
        let h = terrain.h, wl = terrain.waterLevel
        let sea = terrain.cfg.sea
        let spread = WaterRender.deltaArmSpread
        let maxCells = WaterRender.deltaMaxArmCells
        for angle in [-spread, 0.0, spread] {
            let ca = cos(angle), sa = sin(angle)
            let ax = dirX * ca - dirZ * sa, az = dirX * sa + dirZ * ca
            var samples: [RibbonSample] = []
            var reachedFront = false
            var onSea = false
            for stepIndex in 0...maxCells {
                let t = Double(stepIndex)
                let x = mouthX + ax * t, z = mouthZ + az * t
                guard x.isFinite, z.isFinite, abs(x) < 1e9, abs(z) < 1e9 else { break }
                let ci = Int(x.rounded()), cj = Int(z.rounded())
                if ci < 0 || cj < 0 || ci >= n || cj >= n { break }
                let k = cj * n + ci
                guard let surface = openWaterSurface(k, h: h, wl: wl, sea: sea) else { break }
                if surface <= sea { onSea = true }
                if surface - h[k] >= WaterRender.deltaFrontDepth { reachedFront = true; break }
                let f = t / Double(maxCells)
                let armWidth = max(halfWidth, WaterRender.deltaArmMinHalfWidthCells)
                samples.append(RibbonSample(x: x, z: z,
                                            halfWidth: armWidth * (WaterRender.deltaArmWidthAtMouth
                                                - WaterRender.deltaArmWidthTaper * f),
                                            alpha: WaterRender.deltaArmOpacity * (1 - f * f),
                                            rank: rank * WaterRender.deltaArmRankFactor,
                                            surface: surface))
            }
            if samples.count < WaterRender.deltaMinArmCells { continue }
            if !reachedFront && !onSea { continue }
            RiverRibbonRenderer.taperTail(&samples, cells: WaterRender.ribbonTailTaperCells)
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindDelta, still: false,
                       hscale: hscale, lift: lift)
        }
    }

    private func appendOxbowRibbons(_ terrain: Terrain, hscale: Double, lift: Double) {
        let n = terrain.cfg.n
        let h = terrain.h, wl = terrain.waterLevel
        let sea = terrain.cfg.sea
        for index in terrain.meander.oxbows.indices {
            let oxbow = terrain.meander.oxbows[index]
            guard let nodeRange = oxbowNodeRange(count: oxbow.count) else { continue }
            let first = nodeRange.lowerBound, last = nodeRange.upperBound
            let age = index < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[index] : 0
            let fade = clamp01(1 - age / WaterRender.oxbowVisibleYears)
            if fade <= 0 { continue }
            var samples: [RibbonSample] = []
            samples.reserveCapacity(nodeRange.count)
            for nodeIndex in nodeRange {
                let node = oxbow[nodeIndex]
                guard node.x.isFinite, node.z.isFinite,
                      abs(node.x) < 1e9, abs(node.z) < 1e9 else { continue }
                let ci = min(max(Int(node.x.rounded()), 0), n - 1)
                let cj = min(max(Int(node.z.rounded()), 0), n - 1)
                let k = cj * n + ci
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = clamp01(Double(edgeSteps + 1) / WaterRender.oxbowEndFadeSteps)
                var alpha = 0.0
                var surface: Double? = nil
                if let s = openWaterSurface(k, h: h, wl: wl, sea: sea), s > sea {
                    surface = s
                    alpha = WaterRender.oxbowMaximumOpacity * fade * endFade
                        * RiverRibbonRenderer.lakeHandoverFade(pond: s - h[k])
                }
                samples.append(RibbonSample(x: node.x, z: node.z,
                                            halfWidth: WaterRender.oxbowHalfWidthCells,
                                            alpha: alpha, rank: 0, surface: surface))
            }
            if !samples.contains(where: { $0.alpha > WaterRender.ribbonMinimumAlpha }) { continue }
            emitRibbon(samples, terrain, kind: WaterRender.ribbonKindOxbow, still: true,
                       hscale: hscale, lift: lift)
        }
    }
}
