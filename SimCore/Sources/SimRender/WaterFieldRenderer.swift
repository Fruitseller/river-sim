import Foundation
import SimCore

public final class WaterFieldRenderer {
    public init() {}

    var legacyWiden = ProcessInfo.processInfo.environment["RS_WIDEN_DIAMOND"] != nil

    static func fieldSizeMismatchDetail(n: Int, cnt: Int,
                                        fieldCounts: [(name: String, count: Int)]) -> String? {
        guard fieldCounts.contains(where: { $0.count != cnt }) else { return nil }
        let fields = fieldCounts.map { "\($0.name)=\($0.count)" }.joined(separator: ", ")
        return "Feldgrößen-Mismatch: n=\(n), cnt=\(cnt), \(fields)"
    }

    private static func validateFields(n: Int, cnt: Int,
                                       fields: [(name: String, count: Int)]) -> String? {
        fieldSizeMismatchDetail(n: n, cnt: cnt, fieldCounts: fields)
    }

    private var sdS: [Double] = []
    private var lakeS: [Double] = []
    private var dxS: [Double] = []
    private var dzS: [Double] = []
    private var waterStream: [Double] = []
    private var waterWiden: [Double] = []
    private var waterLake: [Double] = []
    private var waterBlur: [Double] = []
    private var waterRawWet: [Bool] = []
    private var waterMask: [Bool] = []
    private var waterComponentFade: [Double] = []
    private var waterSeen: [Bool] = []
    private var waterMDX: [Double] = []
    private var waterMDZ: [Double] = []
    private var waterStamp: [Bool] = []
    private var waterCapStamp: [Bool] = []
    private var waterCapped: [Bool] = []
    private var waterOxbow: [Double] = []
    private var waterBytes: [UInt8] = []
    private var waterComponent: [Int] = []
    private var waterStack: [Int] = []
    private var waterBandQ: [Double] = []
    private(set) var waterDeparture: [Double] = []
    private var waterDepartureOpen: [Bool] = []
    private var waterDeparturePath: [Int] = []
    private var waterPondEntries: [(cell: Int, value: Double)] = []
    public private(set) var wetMeadow: [Bool] = []
    struct ComponentStat {
        let cells: Int
        let banded: Bool
        let visible: Bool
    }
    private(set) var componentStats: [ComponentStat] = []
    private(set) var remnantStats: [Int] = []
    private var flowDetail: [UInt8] = []

    public func flowDetailField(_ terrain: Terrain) -> [UInt8] {
        let n = terrain.cfg.n
        guard n > 0 else { return [] }
        let cnt = n * n
        let h = terrain.h, area = terrain.areaMFD
        if let mismatch = Self.validateFields(
            n: n, cnt: cnt, fields: [("h", h.count), ("areaMFD", area.count)]) {
            assertionFailure(mismatch)
            return []
        }
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells
        if flowDetail.count != cnt { flowDetail = [UInt8](repeating: 0, count: cnt) }
        var out: [UInt8] = []; swap(&out, &flowDetail)
        defer { swap(&out, &flowDetail) }
        guard cellArea > 0, cellArea.isFinite else {
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
            return out
        }
        out.withUnsafeMutableBufferPointer { ob in
        h.withUnsafeBufferPointer { hb in area.withUnsafeBufferPointer { ab in
            let po = ob.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    guard ph[k] > sea else { po[k] = 0; continue }
                    let v = WaterRender.flowDetailIntensity(
                        dischargeCells: pa[k] / cellArea, creekCells: creek)
                    po[k] = UInt8(v * 255.0 + 0.5)
                }
            }
        }}}
        return out
    }

    public func bytes(_ terrain: Terrain, blend: Double, geometryMode: Bool,
                      bandChannelFlags: [Bool], bandCoverage: [Double],
                      bandOwner: [Int32] = [],
                      deferTail: Bool = false) -> [UInt8] {
        let n = terrain.cfg.n
        guard n > 0 else { return [] }
        let cnt = n * n
        let h = terrain.h, hf = terrain.waterLevel, area = terrain.areaMFD, rec = terrain.receiver
        if let mismatch = Self.validateFields(
            n: n, cnt: cnt,
            fields: [("h", h.count), ("waterLevel", hf.count),
                     ("areaMFD", area.count), ("receiver", rec.count),
                     ("streamMap", terrain.streamMap.count)]) {
            assertionFailure(mismatch)
            return []
        }
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells

        if waterStream.count != cnt {
            waterStream = [Double](repeating: 0, count: cnt)
            waterWiden = [Double](repeating: 0, count: cnt)
            waterLake = [Double](repeating: 0, count: cnt)
            waterBlur = [Double](repeating: 0, count: cnt)
            waterMDX = [Double](repeating: 0, count: cnt)
            waterMDZ = [Double](repeating: 0, count: cnt)
            waterOxbow = [Double](repeating: 0, count: cnt)
            waterRawWet = [Bool](repeating: false, count: cnt)
            waterMask = [Bool](repeating: false, count: cnt)
            waterComponentFade = [Double](repeating: 0, count: cnt)
            waterSeen = [Bool](repeating: false, count: cnt)
            waterStamp = [Bool](repeating: false, count: cnt)
            waterCapStamp = [Bool](repeating: false, count: cnt)
            waterCapped = [Bool](repeating: false, count: cnt)
            waterBytes = [UInt8](repeating: 0, count: cnt * 4)
            wetMeadow = [Bool](repeating: false, count: cnt)
            waterComponent.removeAll(keepingCapacity: false)
            waterStack.removeAll(keepingCapacity: false)
        }

        var sd: [Double] = []; swap(&sd, &waterStream)
        var b: [Double] = []; swap(&b, &waterWiden)
        var lk: [Double] = []; swap(&lk, &waterLake)
        var blur: [Double] = []; swap(&blur, &waterBlur)
        var rawWet: [Bool] = []; swap(&rawWet, &waterRawWet)
        var mask: [Bool] = []; swap(&mask, &waterMask)
        var componentFade: [Double] = []; swap(&componentFade, &waterComponentFade)
        var seen: [Bool] = []; swap(&seen, &waterSeen)
        var mdx: [Double] = []; swap(&mdx, &waterMDX)
        var mdz: [Double] = []; swap(&mdz, &waterMDZ)
        var mstamp: [Bool] = []; swap(&mstamp, &waterStamp)
        var capStamp: [Bool] = []; swap(&capStamp, &waterCapStamp)
        var capped: [Bool] = []; swap(&capped, &waterCapped)
        var oxb: [Double] = []; swap(&oxb, &waterOxbow)
        var out: [UInt8] = []; swap(&out, &waterBytes)
        defer {
            swap(&sd, &waterStream); swap(&b, &waterWiden)
            swap(&lk, &waterLake); swap(&blur, &waterBlur)
            swap(&rawWet, &waterRawWet); swap(&mask, &waterMask)
            swap(&componentFade, &waterComponentFade); swap(&seen, &waterSeen)
            swap(&mdx, &waterMDX); swap(&mdz, &waterMDZ)
            swap(&mstamp, &waterStamp); swap(&capStamp, &waterCapStamp)
            swap(&capped, &waterCapped)
            swap(&oxb, &waterOxbow)
            swap(&out, &waterBytes)
        }

        sd.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        let smap = terrain.streamMap
        let clearance = WaterRender.ribbonTrustBandClearanceCells
        let bandNearby = geometryMode && bandCoverage.count == cnt
        b.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        if bandNearby {
            bandCoverage.withUnsafeBufferPointer { cb in
            blur.withUnsafeMutableBufferPointer { rb in
                let pc = cb.baseAddress!, pr = rb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            var m = 0.0
                            for di in max(0, i - clearance)...min(n - 1, i + clearance) {
                                m = max(m, pc[j * n + di])
                            }
                            pr[j * n + i] = m
                        }
                    }
                }
            }}
            blur.withUnsafeBufferPointer { rb in
            b.withUnsafeMutableBufferPointer { nb in
                let pr = rb.baseAddress!, pn = nb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            var m = 0.0
                            for dj in max(0, j - clearance)...min(n - 1, j + clearance) {
                                m = max(m, pr[dj * n + i])
                            }
                            pn[j * n + i] = m
                        }
                    }
                }
            }}
        }
        if waterDeparture.count != cnt {
            waterDeparture = [Double](repeating: 0, count: cnt)
            waterDepartureOpen = [Bool](repeating: false, count: cnt)
        }
        waterDeparture.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        waterDepartureOpen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        let d8Area = terrain.area
        if bandNearby && cellArea > 0 && cellArea.isFinite && d8Area.count == cnt {
            let inBand = WaterRender.rasterBarBandCoverage
            let maxSteps = WaterRender.departureMaxCells
            let owned = bandOwner.count == cnt
            func ownerNear(_ k: Int) -> Int32 {
                guard owned else { return -1 }
                let i = k % n, j = k / n
                var best = -1.0, who: Int32 = -1
                for jj in max(0, j - clearance)...min(n - 1, j + clearance) {
                    for ii in max(0, i - clearance)...min(n - 1, i + clearance) where bandCoverage[jj * n + ii] > best {
                        best = bandCoverage[jj * n + ii]; who = bandOwner[jj * n + ii]
                    }
                }
                return who
            }
            b.withUnsafeBufferPointer { nb in
            waterDeparture.withUnsafeMutableBufferPointer { db in
            waterDepartureOpen.withUnsafeMutableBufferPointer { ob in
                let pnear = nb.baseAddress!, pd = db.baseAddress!, popen = ob.baseAddress!
                for k in 0..<cnt where pnear[k] >= inBand && h[k] > sea {
                    let r = Int(rec[k])
                    guard r >= 0, r < cnt, pnear[r] < inBand, h[r] > sea, pd[r] == 0,
                          d8Area[r] / cellArea >= creek else { continue }
                    waterDeparturePath.removeAll(keepingCapacity: true)
                    if bandCoverage[k] < WaterRender.departureEdgeCoverage { waterDeparturePath.append(k) }
                    let from = ownerNear(k)
                    var x = r, returned = false, open = false
                    while waterDeparturePath.count < maxSteps {
                        waterDeparturePath.append(x)
                        let nx = Int(rec[x])
                        if nx < 0 || nx >= cnt || h[nx] <= sea
                            || hf[nx] - h[nx] > WaterRender.lakeRawWetDepth {
                            open = nx >= 0 && nx < cnt && h[nx] <= sea
                            if nx >= 0 && nx < cnt { waterDeparturePath.append(nx) }
                            break
                        }
                        if pd[nx] > 0 { break }
                        if pnear[nx] >= inBand {
                            let to = ownerNear(nx)
                            returned = !owned || from < 0 || to < 0 || to == from
                            break
                        }
                        x = nx
                    }
                    if returned { continue }
                    var previous = -1
                    for c in waterDeparturePath {
                        let v = WaterRender.streamIntensity(dischargeCells: d8Area[c] / cellArea,
                                                            creekCells: creek)
                        let water = h[c] <= sea || hf[c] - h[c] > WaterRender.lakeRawWetDepth
                        if !water { pd[c] = max(pd[c], v) }
                        if open && !water { popen[c] = true }
                        if previous >= 0, previous % n != c % n, previous / n != c / n {
                            let a = (previous / n) * n + c % n, b2 = (c / n) * n + previous % n
                            let bridge = h[a] <= h[b2] ? a : b2
                            pd[bridge] = max(pd[bridge], v)
                            if open { popen[bridge] = true }
                        }
                        previous = c
                    }
                }
            }}}
        }
        if cellArea > 0, cellArea.isFinite {
            sd.withUnsafeMutableBufferPointer { sdb in
            h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
            area.withUnsafeBufferPointer { ab in smap.withUnsafeBufferPointer { smb in
            b.withUnsafeBufferPointer { nb in
            waterDeparture.withUnsafeBufferPointer { db in
                let psd = sdb.baseAddress!, ph = hb.baseAddress!, phf = hfb.baseAddress!
                let pa = ab.baseAddress!, psm = smb.baseAddress!, pnear = nb.baseAddress!
                let pdep = db.baseAddress!
                parallelChunks(cnt) { lo, hi in
                    for k in lo..<hi where phf[k] > sea && ph[k] > sea
                                           && phf[k] - ph[k] <= WaterRender.streamPondTolerance {
                        psd[k] = pdep[k]
                        let cu = pa[k] / cellArea
                        if cu < creek { continue }
                        let trust = WaterRender.ribbonTrust(dischargeCells: cu, referenceCells: creek)
                            * (1 - min(1, pnear[k]))
                        let m = max(WaterRender.trackMask(streamMap: psm[k]), trust)
                        if m <= 0 { continue }
                        psd[k] = max(pdep[k], WaterRender.streamIntensity(dischargeCells: cu, creekCells: creek)
                            * WaterRender.trackWeight(mask: m))
                    }
                }
            }}}}}}}
        }
        waterPondEntries.removeAll(keepingCapacity: true)
        for start in 0..<(n * n) where sd[start] > WaterRender.continuityFloor {
            var val = max(sd[start] - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
            var r = rec[start]
            while r >= 0 && r < cnt {
                let ri = Int(r)
                if sd[ri] >= val { break }
                if h[ri] <= sea { break }
                if hf[ri] - h[ri] > WaterRender.lakeRawWetDepth {
                    waterPondEntries.append((cell: ri, value: val))
                    break
                }
                sd[ri] = val
                val = max(val - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
                r = rec[ri]
            }
        }
        let barTol = WaterRender.widenBarTolerance
        if legacyWiden {
            let widenThresh = WaterRender.widenThresholds
            let widenFalloff = WaterRender.widenFalloff
            for thresh in widenThresh {
                sd.withUnsafeBufferPointer { sdb in
                b.withUnsafeMutableBufferPointer { bb in
                h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
                    let psd = sdb.baseAddress!, pb = bb.baseAddress!
                    let ph = hb.baseAddress!, phf = hfb.baseAddress!
                    parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            let k = j * n + i
                            var m = psd[k]
                            if i > 0 && psd[k - 1] > thresh && abs(ph[k] - phf[k - 1]) < barTol { m = max(m, psd[k - 1] - widenFalloff) }
                            if i < n - 1 && psd[k + 1] > thresh && abs(ph[k] - phf[k + 1]) < barTol { m = max(m, psd[k + 1] - widenFalloff) }
                            if j > 0 && psd[k - n] > thresh && abs(ph[k] - phf[k - n]) < barTol { m = max(m, psd[k - n] - widenFalloff) }
                            if j < n - 1 && psd[k + n] > thresh && abs(ph[k] - phf[k + n]) < barTol { m = max(m, psd[k + n] - widenFalloff) }
                            pb[k] = m
                        }
                    }
                    }
                }}}}
                swap(&sd, &b)
            }

        } else {
            RiverWidening.widen(sd, into: &b, h: h, hf: hf, receiver: rec, n: n)
            swap(&sd, &b)
        }

        mdx.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        mdz.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        mstamp.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        capStamp.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        oxb.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        let noMeanderPaint = ProcessInfo.processInfo.environment["RS_NO_MEANDER_PAINT"] != nil
        let haloIntensity = WaterRender.ribbonHaloIntensity
        func stampCorridor(cx: Int, cy: Int, rad: Int, intens: Double,
                           dirX: Double, dirZ: Double, capToHalo: Bool) {
            let jLo = max(0, cy - rad), jHi = min(n - 1, cy + rad)
            let iLo = max(0, cx - rad), iHi = min(n - 1, cx + rad)
            if jLo > jHi || iLo > iHi { return }
            for jj in jLo...jHi {
                for ii in iLo...iHi {
                    let dd = (ii - cx) * (ii - cx) + (jj - cy) * (jj - cy)
                    if dd > rad * rad { continue }
                    let kk = jj * n + ii
                    if h[kk] <= sea { continue }
                    let mM = WaterRender.corridorMask(streamMap: smap[kk])
                    let iM = intens * WaterRender.corridorWeight(mask: mM)
                    if sd[kk] < iM { sd[kk] = iM }
                    mstamp[kk] = true; mdx[kk] = dirX; mdz[kk] = dirZ
                    if capToHalo { capStamp[kk] = true }
                }
            }
        }
        for (chIndex, ch) in (noMeanderPaint ? [] : terrain.meander.channels).enumerated() {
            let nodes = ch.nodes
            if nodes.count < 2 { continue }
            guard ch.discharge.count >= nodes.count else { continue }
            guard !nodes.contains(where: {
                !$0.x.isFinite || !$0.z.isFinite || abs($0.x) > 1e9 || abs($0.z) > 1e9
            }) else { continue }
            guard !ch.discharge.prefix(nodes.count).contains(where: { !$0.isFinite || abs($0) > 1e9 }) else { continue }
            let hasBand = geometryMode
                && (chIndex < bandChannelFlags.count ? bandChannelFlags[chIndex] : true)
            if geometryMode && !hasBand { continue }
            for i in 0..<(nodes.count - 1) {
                let ax = nodes[i].x, az = nodes[i].z, bx = nodes[i + 1].x, bz = nodes[i + 1].z
                let q = 0.5 * (ch.discharge[i] + ch.discharge[i + 1])
                if q < creek { continue }
                let hw = hasBand
                    ? ribbonHalfWidthCells(q, cfg: terrain.cfg) + WaterRender.ribbonHaloMarginCells
                    : WaterRender.stampHalfWidthCells(dischargeCells: q, creekCells: creek)
                let rad = Int(hw.rounded())
                let intens = hasBand ? haloIntensity
                    : WaterRender.stampIntensity(dischargeCells: q, creekCells: creek)
                var tx = bx - ax, tz = bz - az
                let tl = (tx * tx + tz * tz).squareRoot(); if tl > 1e-6 { tx /= tl; tz /= tl }
                let steps = max(1, Int(tl.rounded()))
                for s in 0...steps {
                    let t = Double(s) / Double(steps)
                    let cx = Int((ax + (bx - ax) * t).rounded()), cy = Int((az + (bz - az) * t).rounded())
                    stampCorridor(cx: cx, cy: cy, rad: rad, intens: intens,
                                  dirX: tx, dirZ: tz, capToHalo: hasBand)
                }
            }
            if hasBand {
                let last = nodes[nodes.count - 1]
                let q = ch.discharge[nodes.count - 1]
                if q >= creek {
                    let rad = Int((ribbonHalfWidthCells(q, cfg: terrain.cfg)
                                   + WaterRender.ribbonHaloMarginCells).rounded())
                    var previousX = last.x, previousZ = last.z
                    let prior = nodes[max(0, nodes.count - 2)]
                    for point in mouthPath(terrain, fromX: last.x, fromZ: last.z,
                                           dirX: last.x - prior.x, dirZ: last.z - prior.z) {
                        var dirX = point.x - previousX, dirZ = point.z - previousZ
                        let dl = (dirX * dirX + dirZ * dirZ).squareRoot()
                        if dl > 1e-6 { dirX /= dl; dirZ /= dl }
                        stampCorridor(cx: Int(point.x.rounded()), cy: Int(point.z.rounded()),
                                      rad: rad, intens: haloIntensity,
                                      dirX: dirX, dirZ: dirZ, capToHalo: true)
                        previousX = point.x; previousZ = point.z
                    }
                }
            }
        }
        let fullEndFadeSteps = WaterRender.oxbowEndFadeSteps
        let minimumPondDepth = WaterRender.pondContourLo
        let maximumOxbowOpacity = WaterRender.oxbowMaximumOpacity
        for oxbowIndex in terrain.meander.oxbows.indices {
            let oxbow = terrain.meander.oxbows[oxbowIndex]
            guard let nodeRange = oxbowNodeRange(count: oxbow.count) else { continue }
            let first = nodeRange.lowerBound, last = nodeRange.upperBound
            let age = oxbowIndex < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[oxbowIndex]
                : 0
            let fade = clamp01(1 - age / WaterRender.oxbowVisibleYears)
            if fade <= 0 { continue }
            for nodeIndex in nodeRange {
                let node = oxbow[nodeIndex]
                guard node.x.isFinite, node.z.isFinite,
                      abs(node.x) < 1e9, abs(node.z) < 1e9 else { continue }
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = clamp01(Double(edgeSteps + 1) / fullEndFadeSteps)
                let centerX = Int(node.x.rounded()), centerY = Int(node.z.rounded())
                for (offsetX, offsetY) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let neighborX = centerX + offsetX, neighborY = centerY + offsetY
                    if neighborX < 0 || neighborX >= n || neighborY < 0 || neighborY >= n {
                        continue
                    }
                    let cellIndex = neighborY * n + neighborX
                    let pondDepth = hf[cellIndex] - h[cellIndex]
                    if hf[cellIndex] <= sea || h[cellIndex] <= sea || pondDepth <= minimumPondDepth {
                        continue
                    }
                    let value = maximumOxbowOpacity * fade * endFade
                    if oxb[cellIndex] < value { oxb[cellIndex] = value }
                }
            }
        }

        rawWet.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        capped.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        let barAge = terrain.barAge
        let barCheck = geometryMode && bandCoverage.count == cnt && barAge.count == cnt
            && cellArea > 0 && cellArea.isFinite
        if barCheck {
            if waterBandQ.count != cnt { waterBandQ = [Double](repeating: 0, count: cnt) }
            waterBandQ.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
            for (chIndex, ch) in terrain.meander.channels.enumerated()
            where chIndex < bandChannelFlags.count && bandChannelFlags[chIndex] {
                for (i, node) in ch.nodes.enumerated() where i < ch.discharge.count {
                    guard node.x.isFinite, node.z.isFinite, ch.discharge[i].isFinite else { continue }
                    let ci = min(max(Int(node.x.rounded()), 0), n - 1)
                    let cj = min(max(Int(node.z.rounded()), 0), n - 1)
                    let k = cj * n + ci
                    if bandCoverage[k] >= WaterRender.rasterBarBandCoverage {
                        waterBandQ[k] = max(waterBandQ[k], ch.discharge[i])
                    }
                }
            }
        }
        let reach = WaterRender.rasterBarBandReachCells
        let bandQ = waterBandQ
        for k in 0..<cnt {
            if barCheck && barAge[k] >= 0 && sd[k] > haloIntensity && waterDeparture[k] == 0 {
                let need = WaterRender.rasterBarBandDischargeRatio * area[k] / cellArea
                let i = k % n, j = k / n
                var found = false
                search: for jj in max(0, j - reach)...min(n - 1, j + reach) {
                    for ii in max(0, i - reach)...min(n - 1, i + reach) where bandQ[jj * n + ii] >= need
                        && bandQ[jj * n + ii] > 0 {
                        found = true; break search
                    }
                }
                if found { sd[k] = haloIntensity }
            }
            let lagoon = h[k] <= sea && hf[k] - sea < WaterRender.lagoonMaxRise
            rawWet[k] = hf[k] > sea && hf[k] - h[k] > WaterRender.lakeRawWetDepth && !lagoon
            if geometryMode {
                if oxb[k] > 0 {
                    if sd[k] < haloIntensity { sd[k] = haloIntensity }
                    mstamp[k] = true
                    capStamp[k] = true
                }
                let cover = k < bandCoverage.count ? bandCoverage[k] : 1.0
                if capStamp[k] && sd[k] > haloIntensity {
                    sd[k] += (haloIntensity - sd[k]) * cover
                    if cover >= WaterRender.remnantMinBandCoverage { capped[k] = true }
                }
            }
            mask[k] = rawWet[k] || sd[k] >= WaterRender.riverMaskLo
        }
        componentFade.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        seen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        wetMeadow.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        remnantStats.removeAll(keepingCapacity: true)
        waterComponent.removeAll(keepingCapacity: true)
        waterStack.removeAll(keepingCapacity: true)
        let departureOpen = waterDepartureOpen
        for start in 0..<cnt where mask[start] && !seen[start] {
            waterComponent.removeAll(keepingCapacity: true)
            waterStack.removeAll(keepingCapacity: true)
            waterStack.append(start); seen[start] = true
            var allCapped = true
            var departs = false
            while let k = waterStack.popLast() {
                waterComponent.append(k)
                if departureOpen[k] { departs = true }
                if !capped[k] || rawWet[k] { allCapped = false }
                let i = k % n, j = k / n
                if i > 0 && mask[k - 1] && !seen[k - 1] { seen[k - 1] = true; waterStack.append(k - 1) }
                if i < n - 1 && mask[k + 1] && !seen[k + 1] { seen[k + 1] = true; waterStack.append(k + 1) }
                if j > 0 && mask[k - n] && !seen[k - n] { seen[k - n] = true; waterStack.append(k - n) }
                if j < n - 1 && mask[k + n] && !seen[k + n] { seen[k + n] = true; waterStack.append(k + n) }
            }
            if allCapped && waterComponent.count < WaterRender.wetMeadowMaxCells {
                remnantStats.append(waterComponent.count)
                for k in waterComponent {
                    if sd[k] > haloIntensity { sd[k] = haloIntensity }
                    wetMeadow[k] = true
                }
                continue
            }
            let fade = departs ? 1 : WaterRender.componentFade(cells: waterComponent.count)
            if fade > 0 {
                for k in waterComponent { componentFade[k] = fade }
            }
        }
        seen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        componentStats.removeAll(keepingCapacity: true)
        for start in 0..<cnt where rawWet[start] && !seen[start] {
            waterComponent.removeAll(keepingCapacity: true)
            waterStack.removeAll(keepingCapacity: true)
            waterStack.append(start); seen[start] = true
            var banded = false
            while let k = waterStack.popLast() {
                waterComponent.append(k)
                let i = k % n, j = k / n
                if mstamp[k] || (i > 0 && mstamp[k - 1]) || (i < n - 1 && mstamp[k + 1])
                    || (j > 0 && mstamp[k - n]) || (j < n - 1 && mstamp[k + n]) {
                    banded = true
                }
                if i > 0 && rawWet[k - 1] && !seen[k - 1] { seen[k - 1] = true; waterStack.append(k - 1) }
                if i < n - 1 && rawWet[k + 1] && !seen[k + 1] { seen[k + 1] = true; waterStack.append(k + 1) }
                if j > 0 && rawWet[k - n] && !seen[k - n] { seen[k - n] = true; waterStack.append(k - n) }
                if j < n - 1 && rawWet[k + n] && !seen[k + n] { seen[k + n] = true; waterStack.append(k + n) }
            }
            let visible = waterComponent.contains { componentFade[$0] > 0 }
            componentStats.append(ComponentStat(cells: waterComponent.count,
                                                banded: banded, visible: visible))
            if WaterRender.isWetMeadow(pondCells: waterComponent.count, banded: banded) {
                for k in waterComponent { wetMeadow[k] = true }
            }
        }
        for entry in waterPondEntries where wetMeadow[entry.cell] {
            var val = entry.value
            var ri = entry.cell
            while sd[ri] < val {
                sd[ri] = val
                val = max(val - WaterRender.continuityDecayPerCell,
                          WaterRender.continuityFloor)
                let r = rec[ri]
                guard r >= 0 && r < cnt else { break }
                ri = Int(r)
                if h[ri] <= sea { break }
                if hf[ri] - h[ri] > WaterRender.lakeRawWetDepth && !wetMeadow[ri] { break }
            }
        }

        sd.withUnsafeMutableBufferPointer { sdb in
        lk.withUnsafeMutableBufferPointer { lkb in
        mstamp.withUnsafeBufferPointer { msb in
        componentFade.withUnsafeBufferPointer { cfb in
        rawWet.withUnsafeBufferPointer { rwb in
        wetMeadow.withUnsafeBufferPointer { wmb in
        oxb.withUnsafeBufferPointer { oxbPtr in
            let pwm = wmb.baseAddress!
            let psd = sdb.baseAddress!, plk = lkb.baseAddress!
            let pms = msb.baseAddress!, pcf = cfb.baseAddress!
            let prw = rwb.baseAddress!, pox = oxbPtr.baseAddress!
            plk.update(repeating: 0, count: cnt)
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    let gate = WaterRender.streamGate(componentFade: pcf[k])
                    if geometryMode && pms[k] {
                        if gate == 0 && psd[k] > haloIntensity { psd[k] = haloIntensity }
                    } else {
                        psd[k] *= gate
                    }
                    if prw[k] && !pwm[k] { plk[k] = pcf[k] }
                    if !geometryMode && pox[k] > plk[k] { plk[k] = pox[k] }
                }
            }
        }}}}}}}
        func blur3(_ src: [Double], into dst: inout [Double]) {
            src.withUnsafeBufferPointer { sb in
            dst.withUnsafeMutableBufferPointer { db in
                let ps = sb.baseAddress!, pd = db.baseAddress!
                parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let k = j * n + i
                        var s = 0.0, c = 0.0
                        for dj in max(0, j-1)...min(n-1, j+1) {
                            for di in max(0, i-1)...min(n-1, i+1) {
                                s += ps[dj * n + di]; c += 1
                            }
                        }
                        pd[k] = s / c
                    }
                }
                }
            }}
        }
        func blurMax(_ field: inout [Double], passes: Int) {
            for _ in 0..<passes {
                blur3(field, into: &blur)
                field.withUnsafeMutableBufferPointer { fb in
                blur.withUnsafeBufferPointer { bb in
                    let pf = fb.baseAddress!, pb = bb.baseAddress!
                    parallelChunks(cnt) { lo, hi in
                        for k in lo..<hi { pf[k] = max(pf[k], pb[k]) }
                    }
                }}
            }
        }
        if deferTail {
            out.withUnsafeMutableBufferPointer { ob in
            rec.withUnsafeBufferPointer { rcb in
            sd.withUnsafeBufferPointer { sdb in
            lk.withUnsafeBufferPointer { lkb in
            mstamp.withUnsafeBufferPointer { msb in
            mdx.withUnsafeBufferPointer { mdxb in
            mdz.withUnsafeBufferPointer { mdzb in
                let pout = ob.baseAddress!, prec = rcb.baseAddress!
                let psd = sdb.baseAddress!, plk = lkb.baseAddress!
                let pms = msb.baseAddress!, pmdx = mdxb.baseAddress!, pmdz = mdzb.baseAddress!
                parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    var dx = 0.0, dz = 0.0
                    if pms[k] {
                        dx = pmdx[k]; dz = pmdz[k]
                    } else {
                        let r = prec[k]
                        if r >= 0 && r < cnt { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                    }
                    let o = k * 4
                    pout[o] = byte01(psd[k])
                    pout[o + 1] = byte01(plk[k])
                    pout[o + 2] = byte01(min(1, max(-1, dx)) * 0.5 + 0.5)
                    pout[o + 3] = byte01(min(1, max(-1, dz)) * 0.5 + 0.5)
                }
                }
            }}}}}}}
            return out
        }

        blurMax(&sd, passes: WaterTailPlan.streamBlurPasses)
        blurMax(&lk, passes: WaterTailPlan.lakeBlurPasses)

        if sdS.count != cnt {
            sdS = [Double](repeating: 0, count: cnt)
            lakeS = [Double](repeating: 0, count: cnt)
            dxS = [Double](repeating: 0, count: cnt)
            dzS = [Double](repeating: 0, count: cnt)
        }
        let bl = clamp01(blend)
        let jump = bl >= 1.0

        sdS.withUnsafeMutableBufferPointer { s1 in
        lakeS.withUnsafeMutableBufferPointer { s2 in
        dxS.withUnsafeMutableBufferPointer { s3 in
        dzS.withUnsafeMutableBufferPointer { s4 in
        out.withUnsafeMutableBufferPointer { ob in
        rec.withUnsafeBufferPointer { rcb in
        sd.withUnsafeBufferPointer { sdb in
        lk.withUnsafeBufferPointer { lkb in
        mstamp.withUnsafeBufferPointer { msb in
        mdx.withUnsafeBufferPointer { mdxb in
        mdz.withUnsafeBufferPointer { mdzb in
            let psdS = s1.baseAddress!, plakeS = s2.baseAddress!
            let pdxS = s3.baseAddress!, pdzS = s4.baseAddress!
            let pout = ob.baseAddress!, prec = rcb.baseAddress!
            let psd = sdb.baseAddress!, plk = lkb.baseAddress!
            let pms = msb.baseAddress!, pmdx = mdxb.baseAddress!, pmdz = mdzb.baseAddress!
            parallelChunks(cnt) { lo, hi in
            for k in lo..<hi {
                let lake = plk[k]
                var dx = 0.0, dz = 0.0
                if pms[k] {
                    dx = pmdx[k]; dz = pmdz[k]
                } else {
                    let r = prec[k]
                    if r >= 0 && r < cnt { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                }
                psdS[k]   = jump ? psd[k] : psdS[k] + bl * (psd[k] - psdS[k])
                plakeS[k] = jump ? lake   : plakeS[k] + bl * (lake - plakeS[k])
                pdxS[k]   = jump ? dx     : pdxS[k] + bl * (dx - pdxS[k])
                pdzS[k]   = jump ? dz     : pdzS[k] + bl * (dz - pdzS[k])
                let o = k * 4
                pout[o] = byte01(psdS[k])
                pout[o + 1] = byte01(plakeS[k])
                pout[o + 2] = byte01(min(1, max(-1, pdxS[k])) * 0.5 + 0.5)
                pout[o + 3] = byte01(min(1, max(-1, pdzS[k])) * 0.5 + 0.5)
            }
            }
        }}}}}}}}}}}
        return out
    }
}
