import Foundation
import SimCore

enum RiverWidening {
    @inline(__always)
    private static func noise(_ x: Double, _ y: Double, _ salt: UInt32) -> Double {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(truncatingIfNeeded: Int(fx)), iy = Int32(truncatingIfNeeded: Int(fy))
        let tx = x - fx, ty = y - fy
        let u = tx * tx * (3 - 2 * tx), v = ty * ty * (3 - 2 * ty)
        @inline(__always) func lattice(_ a: Int32, _ b: Int32) -> Double {
            var h = UInt32(bitPattern: a) &* 0x9E3779B1 ^ UInt32(bitPattern: b) &* 0x85EBCA77 ^ salt
            h ^= h >> 15; h = h &* 0x2C1B3C6D
            h ^= h >> 12; h = h &* 0x297A2D39
            h ^= h >> 15
            return Double(h) / 2147483648.0 - 1
        }
        let a = lattice(ix, iy), b = lattice(ix &+ 1, iy)
        let c = lattice(ix, iy &+ 1), d = lattice(ix &+ 1, iy &+ 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    static func widen(_ sd: [Double], into out: inout [Double],
                      h: [Double], hf: [Double], receiver: [Int32], n: Int) {
        let cnt = n * n
        precondition(sd.count == cnt && out.count == cnt && h.count == cnt
                     && hf.count == cnt && receiver.count == cnt)
        let t0 = WaterRender.widenThresholds[0]
        let falloff = WaterRender.widenFalloff
        let tolerance = WaterRender.widenBarTolerance
        let jitter = WaterRender.widenWidthJitter
        let wander = WaterRender.widenWanderRadii
        let frequency = 1.0 / WaterRender.widenWavelengthCells
        let taperCells = WaterRender.widenHeadTaperCells
        let shoulder = WaterRender.widenShoulderCells

        var upstream = [UInt8](repeating: 0, count: cnt)
        var strong: [Int32] = []
        strong.reserveCapacity(8192)
        sd.withUnsafeBufferPointer { sb in
            for k in 0..<cnt where sb[k] > t0 { strong.append(Int32(k)) }
        }
        for k32 in strong {
            let k = Int(k32)
            var r = receiver[k]
            var steps = 0
            while r >= 0 && Int(r) < cnt && steps < taperCells {
                let v = Int(r)
                if sd[v] > t0 && upstream[v] < UInt8(taperCells) { upstream[v] += 1 }
                r = receiver[v]
                steps += 1
            }
        }

        let crowd = WaterRender.widenCrowdCells
        var strongMask = [Bool](repeating: false, count: cnt)
        for k32 in strong { strongMask[Int(k32)] = true }

        sd.withUnsafeBufferPointer { sb in
        out.withUnsafeMutableBufferPointer { ob in
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { fb in
        upstream.withUnsafeBufferPointer { ub in
            let ps = sb.baseAddress!, po = ob.baseAddress!
            let ph = hb.baseAddress!, pf = fb.baseAddress!, pu = ub.baseAddress!
            po.update(from: ps, count: cnt)
            for k32 in strong {
                let k = Int(k32)
                let i = k % n, j = k / n
                let s = ps[k]
                let taper = WaterRender.widenHeadTaper(upstreamCells: Int(pu[k]))
                var around = 0
                for dj in max(0, j - crowd)...min(n - 1, j + crowd) {
                    let row = dj * n
                    for di in max(0, i - crowd)...min(n - 1, i + crowd) where strongMask[row + di] { around += 1 }
                }
                let side = 2 * crowd + 1
                let share = Double(around) / Double(side * side)
                let base = WaterRender.widenRadius(intensity: s) * taper * WaterRender.widenCrowdFactor(share: share)
                let x = Double(i), z = Double(j)
                let radius = base * (1 + jitter * noise(x * frequency, z * frequency, 0x1A5))
                let shift = wander * base
                let cx = x + shift * noise(x * frequency, z * frequency, 0x2B6)
                let cz = z + shift * noise(x * frequency, z * frequency, 0x3C7)
                let reach = radius + shoulder
                let iLo = max(0, Int((cx - reach).rounded(.down)))
                let iHi = min(n - 1, Int((cx + reach).rounded(.up)))
                let jLo = max(0, Int((cz - reach).rounded(.down)))
                let jHi = min(n - 1, Int((cz + reach).rounded(.up)))
                if iLo > iHi || jLo > jHi { continue }
                let level = pf[k]
                let core = s - falloff * radius
                for tj in jLo...jHi {
                    for ti in iLo...iHi {
                        let dx = Double(ti) - cx, dz = Double(tj) - cz
                        let d = (dx * dx + dz * dz).squareRoot()
                        if d >= reach { continue }
                        let t = tj * n + ti
                        if t != k && abs(ph[t] - level) >= tolerance { continue }
                        let v = d <= radius ? s - falloff * d : core * (1 - (d - radius) / shoulder)
                        if v > po[t] { po[t] = v }
                    }
                }
            }
        }}}}}
    }
}
