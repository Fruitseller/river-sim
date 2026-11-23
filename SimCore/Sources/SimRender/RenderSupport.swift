import Foundation
import SimCore

private let hostCoreCount = ProcessInfo.processInfo.activeProcessorCount
@inline(__always) public func parallelChunks(_ count: Int, _ body: (Int, Int) -> Void) {
    let chunks = min(count, max(1, hostCoreCount * 4))
    if chunks <= 1 { body(0, count); return }
    nonisolated(unsafe) let unsafeBody = body
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        unsafeBody(count * c / chunks, count * (c + 1) / chunks)
    }
}

@inline(__always)
func clamp01(_ value: Double) -> Double {
    min(1, max(0, value))
}

@inline(__always)
func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

@inline(__always)
func byte01(_ value: Double) -> UInt8 {
    guard value > 0 else { return 0 }
    guard value < 1 else { return 255 }
    return UInt8(value * 255)
}

@inline(__always)
func bilinearGrid(_ field: [Double], _ gx: Double, _ gz: Double, n: Int) -> Double {
    guard n >= 2, field.count >= n * n,
          gx.isFinite, gz.isFinite,
          abs(gx) < 1e9, abs(gz) < 1e9 else {
        if n == 1 && field.count >= 1 { return field[0] }
        return 0
    }
    let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
    let fx = clamp01(gx - Double(xi)), fy = clamp01(gz - Double(yi))
    let k = yi * n + xi
    return field[k] * (1 - fx) * (1 - fy) + field[k + 1] * fx * (1 - fy)
         + field[k + n] * (1 - fx) * fy + field[k + n + 1] * fx * fy
}

@inline(__always)
func renderSurfaceHeight(_ field: [Double], _ gx: Double, _ gz: Double,
                         n: Int, renderGrid: Int) -> Double {
    guard n >= 2, field.count >= n * n,
          gx.isFinite, gz.isFinite,
          abs(gx) < 1e9, abs(gz) < 1e9 else {
        return bilinearGrid(field, gx, gz, n: n)
    }
    if renderGrid <= 1 || renderGrid >= n { return bilinearGrid(field, gx, gz, n: n) }
    let s = Double(n - 1) / Double(renderGrid - 1)
    let rx = gx / s, rz = gz / s
    let xi = min(max(Int(rx), 0), renderGrid - 2)
    let zi = min(max(Int(rz), 0), renderGrid - 2)
    let fx = clamp01(rx - Double(xi)), fz = clamp01(rz - Double(zi))
    let v00 = bilinearGrid(field, Double(xi) * s, Double(zi) * s, n: n)
    let v10 = bilinearGrid(field, Double(xi + 1) * s, Double(zi) * s, n: n)
    let v01 = bilinearGrid(field, Double(xi) * s, Double(zi + 1) * s, n: n)
    let v11 = bilinearGrid(field, Double(xi + 1) * s, Double(zi + 1) * s, n: n)
    return fx + fz <= 1
        ? v00 + fx * (v10 - v00) + fz * (v01 - v00)
        : v11 + (1 - fx) * (v01 - v11) + (1 - fz) * (v10 - v11)
}

@inline(__always)
func openWaterSurface(_ k: Int, h: [Double], wl: [Double], sea: Double) -> Double? {
    guard k >= 0, k < h.count, k < wl.count else { return nil }
    if h[k] <= sea { return sea }
    let pond = wl[k] - h[k]
    if wl[k] > sea && pond > WaterRender.pondContourLo { return wl[k] }
    return nil
}

func oxbowNodeRange(count: Int) -> ClosedRange<Int>? {
    guard count >= WaterRender.oxbowMinimumNodes else { return nil }
    let trim = min(WaterRender.oxbowMaximumTrimmedNodes, max(1, count / 8))
    let first = trim, last = count - trim - 1
    guard last - first >= 2 else { return nil }
    return first...last
}

@inline(__always)
func ribbonHalfWidthCells(_ q: Double, cfg: SimConfig) -> Double {
    WaterRender.ribbonHalfWidthCells(dischargeCells: q,
                                     referenceCells: cfg.renderMinCells)
}

func mouthPath(_ terrain: Terrain, fromX: Double, fromZ: Double,
               dirX: Double = 0, dirZ: Double = 0) -> [(x: Double, z: Double, surface: Double?)] {
    let n = terrain.cfg.n
    guard n > 0, terrain.h.count >= n * n,
          terrain.receiver.count >= n * n, terrain.waterLevel.count >= n * n,
          fromX.isFinite, fromZ.isFinite,
          abs(fromX) < 1e9, abs(fromZ) < 1e9 else { return [] }
    let h = terrain.h, wl = terrain.waterLevel, rec = terrain.receiver
    let sea = terrain.cfg.sea
    if dirX.isFinite, dirZ.isFinite,
       let ray = mouthRay(n: n, h: h, wl: wl, sea: sea, fromX: fromX, fromZ: fromZ, dirX: dirX, dirZ: dirZ) {
        return ray
    }
    let i0 = min(max(Int(fromX.rounded()), 0), n - 1)
    let j0 = min(max(Int(fromZ.rounded()), 0), n - 1)
    var k = j0 * n + i0
    var path: [(x: Double, z: Double, surface: Double?)] = []
    var wetCells = 0.0
    for _ in 0..<WaterRender.mouthSearchCells {
        let r = rec[k]
        if r < 0 || r >= n * n { break }
        k = Int(r)
        let surface = openWaterSurface(k, h: h, wl: wl, sea: sea)
        path.append((Double(k % n), Double(k / n), surface))
        if surface != nil {
            wetCells += 1
            if wetCells >= WaterRender.mouthOverlapCells + 1 { break }
        }
    }
    guard path.contains(where: { $0.surface != nil }) else { return [] }
    while let last = path.last, last.surface == nil { path.removeLast() }
    if let last = path.last, let surface = last.surface, surface <= sea {
        var dx = last.x - fromX, dz = last.z - fromZ
        let dl = (dx * dx + dz * dz).squareRoot()
        if dl > 1e-9 {
            dx /= dl; dz /= dl
            var x = last.x, z = last.z
            while wetCells < WaterRender.mouthSeaCells {
                x += dx; z += dz
                let ci = Int(x.rounded()), cj = Int(z.rounded())
                guard ci >= 0, ci < n, cj >= 0, cj < n,
                      let s = openWaterSurface(cj * n + ci, h: h, wl: wl, sea: sea), s <= sea
                else { break }
                path.append((x, z, s))
                wetCells += 1
            }
        }
    }
    var smooth = [(x: fromX, z: fromZ)] + path.map { (x: $0.x, z: $0.z) }
    for _ in 0..<3 {
        let raw = smooth
        for a in 1..<max(raw.count - 1, 1) {
            smooth[a].x = 0.5 * raw[a].x + 0.25 * (raw[a - 1].x + raw[a + 1].x)
            smooth[a].z = 0.5 * raw[a].z + 0.25 * (raw[a - 1].z + raw[a + 1].z)
        }
    }
    for a in path.indices { path[a].x = smooth[a + 1].x; path[a].z = smooth[a + 1].z }
    return path
}

private func mouthRay(n: Int, h: [Double], wl: [Double], sea: Double, fromX: Double, fromZ: Double,
                      dirX: Double, dirZ: Double) -> [(x: Double, z: Double, surface: Double?)]? {
    let dl = (dirX * dirX + dirZ * dirZ).squareRoot()
    guard dl > 1e-9 else { return nil }
    let ux = dirX / dl, uz = dirZ / dl
    var path: [(x: Double, z: Double, surface: Double?)] = []
    var x = fromX, z = fromZ, land = 0, wet = 0.0
    while wet < WaterRender.mouthSeaCells {
        x += ux; z += uz
        let ci = Int(x.rounded()), cj = Int(z.rounded())
        guard ci >= 0, ci < n, cj >= 0, cj < n else { break }
        let surface = openWaterSurface(cj * n + ci, h: h, wl: wl, sea: sea)
        if let s = surface {
            if s > sea { return wet > 0 ? path : nil }
            wet += 1
        } else {
            if wet > 0 { break }
            land += 1
            if land > WaterRender.mouthRayLandCells { return nil }
        }
        path.append((x, z, surface))
    }
    return wet > 0 ? path : nil
}
