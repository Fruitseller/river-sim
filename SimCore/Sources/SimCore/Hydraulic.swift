import Foundation

public struct HydraulicParams: Sendable, Codable, Equatable {
    public var inertia = 0.05
    public var capacity = 4.0
    public var minSlope = 0.01
    public var erodeRate = 0.3
    public var depositRate = 0.3
    public var evaporate = 0.02
    public var gravity = 4.0
    public var maxSteps = 144
    public var erodeRadius = 3
    public var initialWater = 1.0
    public var initialSpeed = 1.0
    public var streamEvapDamp = 0.5
    public var poolDepth = 0.03
    public var poolSedimentKeep = 0.1
    public var channelDepositDamp = 0.15
    public init() {}

    public var isFinite: Bool {
        inertia.isFinite && capacity.isFinite && minSlope.isFinite
            && erodeRate.isFinite && depositRate.isFinite && evaporate.isFinite
            && gravity.isFinite && initialWater.isFinite && initialSpeed.isFinite
            && streamEvapDamp.isFinite && poolDepth.isFinite
            && poolSedimentKeep.isFinite && channelDepositDamp.isFinite
    }
}

public enum Hydraulic {
    static let spawnRejectionTries = 24

    @inline(__always)
    static func dropRNG(seed: UInt32, index: UInt64) -> Mulberry32 {
        var z = index &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        var r = Mulberry32(seed: seed &+ UInt32(truncatingIfNeeded: z))
        _ = r.next()
        return r
    }

    static func spawnPosition(_ rnd: inout Mulberry32, n: Int,
                              weight: [Double], weightMax: Double) -> (x: Double, y: Double) {
        weight.withUnsafeBufferPointer {
            spawnPosition(&rnd, n: n, weight: $0.baseAddress, weightMax: weightMax)
        }
    }

    @inline(__always) static func spawnPosition(_ rnd: inout Mulberry32, n: Int,
                                                weight: UnsafePointer<Double>?, weightMax: Double) -> (x: Double, y: Double) {
        var px = rnd.next() * Double(n - 1)
        var py = rnd.next() * Double(n - 1)
        guard let weight, weightMax > 0 else { return (px, py) }
        var tries = 0
        while true {
            let w = weight[Int(py) * n + Int(px)]
            if w >= weightMax { break }
            if rnd.next() * weightMax <= w { break }
            if tries >= spawnRejectionTries { break }
            tries += 1
            px = rnd.next() * Double(n - 1)
            py = rnd.next() * Double(n - 1)
        }
        return (px, py)
    }

    public static func erode(h: inout [Double], rock: inout [Double], sed: inout [Double],
                              n: Int, count: Int, seed: UInt32, floor: Double,
                              p: HydraulicParams,
                              seaLevel: Double? = nil,
                              firstDrop: UInt64? = nil,
                              hf: [Double] = [], receiver: [Int32] = [],
                             stream: [Double] = [], channel: [Bool] = [],
                             depositDamp: [Double] = [],
                             bedLocked: [Bool] = [],
                             flowWeight: [Double] = [],
                             erodibility: [Double] = [],
                             track: inout [Double]) {
        guard count > 0, n > 2, floor.isFinite, p.isFinite,
              seaLevel?.isFinite ?? true,
              h.count == n * n,
              rock.count == n * n,
              sed.count == n * n else { return }
        var bx: [Int] = [], byv: [Int] = [], bw: [Double] = []
        let r = p.erodeRadius
        if r <= 0 {
            bx = [0]; byv = [0]; bw = [1.0]
        } else {
            var wsum = 0.0
            for dy in -r...r {
                for dx in -r...r {
                    let d = (Double(dx * dx + dy * dy)).squareRoot()
                    if d > Double(r) { continue }
                    let w = 1 - d / Double(r)
                    bx.append(dx); byv.append(dy); bw.append(w); wsum += w
                }
            }
            for i in bw.indices { bw[i] /= wsum }
        }

        let chanOn = channel.count == h.count
        let ddOn = depositDamp.count == h.count
        let lithOn = erodibility.count == h.count
        let iceOn = bedLocked.count == h.count
        let trackOn = track.count == h.count
        let poolOn = hf.count == h.count
        let recOn = receiver.count == h.count
        let streamOn = stream.count == h.count
        let flowOn = flowWeight.count == h.count

        let flowMax: Double = !flowOn ? 0 : flowWeight.withUnsafeBufferPointer { rb in
            guard let pw = rb.baseAddress, rb.count > 0 else { return 0 }
            var m = pw[0]
            for k in 1..<rb.count where pw[k] > m { m = pw[k] }
            return m
        }

        h.withUnsafeMutableBufferPointer { hb in
        rock.withUnsafeMutableBufferPointer { rkb in
        sed.withUnsafeMutableBufferPointer { sb in
        track.withUnsafeMutableBufferPointer { trb in
        channel.withUnsafeBufferPointer { chb in
        depositDamp.withUnsafeBufferPointer { ddb in
        erodibility.withUnsafeBufferPointer { erb in
        bedLocked.withUnsafeBufferPointer { blb in
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeBufferPointer { rcb in
        stream.withUnsafeBufferPointer { stmb in
        flowWeight.withUnsafeBufferPointer { fwb in
        bx.withUnsafeBufferPointer { bxb in
        byv.withUnsafeBufferPointer { byb in
        bw.withUnsafeBufferPointer { bwb in
            let ph = hb.baseAddress!, prock = rkb.baseAddress!, psed = sb.baseAddress!
            let ptrack = trb.baseAddress
            let pchan = chb.baseAddress, pdd = ddb.baseAddress, plith = erb.baseAddress
            let pice = blb.baseAddress, phf = hfb.baseAddress, prec = rcb.baseAddress
            let pstream = stmb.baseAddress, pflow = flowOn ? fwb.baseAddress : nil
            let pbx = bxb.baseAddress!, pby = byb.baseAddress!, pbw = bwb.baseAddress!
            let brushCount = bx.count
            let bed = Terrain.Bed(h: ph, sed: psed, rock: prock,
                                  locked: iceOn ? pice! : nil)

            @inline(__always) func dig(_ k: Int, _ amount: Double) -> Double {
                var d = amount
                let f = lithOn ? plith![k] : 1.0
                if f != 1.0 {
                    let s = psed[k]
                    if d > s { d = s + (d - s) * f }
                }
                let room = ph[k] - floor
                if room <= 0 { return 0 }
                if d > room { d = room }
                return bed.erode(k, d)
            }

            @inline(__always) func deposit(_ k: Int, _ amount: Double) -> Double {
                var f = 1.0
                if chanOn && pchan![k] { f = p.channelDepositDamp }
                if ddOn && pdd![k] < f { f = pdd![k] }
                if f >= 1 { return amount - bed.deposit(k, amount) }
                return amount - bed.deposit(k, amount * f)
            }

            var batch = Mulberry32(seed: seed)
            for i in 0..<count {
                var px = 0.0, py = 0.0
                if let firstDrop {
                    var rnd = dropRNG(seed: seed, index: firstDrop &+ UInt64(i))
                    (px, py) = spawnPosition(&rnd, n: n, weight: pflow, weightMax: flowMax)
                } else {
                    (px, py) = spawnPosition(&batch, n: n, weight: pflow, weightMax: flowMax)
                }
                if let seaLevel {
                    let start = Int(py) * n + Int(px)
                    if ph[start] <= seaLevel { continue }
                }
                var dirX = 0.0, dirY = 0.0
                var speed = p.initialSpeed, water = p.initialWater, sediment = 0.0

                for step in 0..<p.maxSteps {
                    let nodeX = Int(px), nodeY = Int(py)
                    if nodeX < 0 || nodeX >= n - 1 || nodeY < 0 || nodeY >= n - 1 { break }
                    let fx = px - Double(nodeX), fy = py - Double(nodeY)
                    let k = nodeY * n + nodeX
                    if trackOn { ptrack![k] += min(1.0, Double(step) / 40) }

                    if poolOn && phf![k] - ph[k] > p.poolDepth {
                        let dep = sediment * (1 - p.poolSedimentKeep)
                        sediment -= dep - deposit(k, dep)
                        var c = k, guardN = 0
                        var exited = false
                        if recOn {
                            while guardN < 4 * n {
                                guardN += 1
                                let r = prec![c]
                                if r < 0 || r >= n * n { break }
                                c = Int(r)
                                if phf![c] - ph[c] <= p.poolDepth { exited = true; break }
                            }
                        }
                        if !exited { break }
                        px = Double(c % n); py = Double(c / n)
                        dirX = 0; dirY = 0
                        speed = p.initialSpeed
                        continue
                    }
                    let hNW = ph[k], hNE = ph[k + 1], hSW = ph[k + n], hSE = ph[k + n + 1]
                    let gradX = (hNE - hNW) * (1 - fy) + (hSE - hSW) * fy
                    let gradY = (hSW - hNW) * (1 - fx) + (hSE - hNE) * fx
                    let height = hNW * (1 - fx) * (1 - fy) + hNE * fx * (1 - fy)
                               + hSW * (1 - fx) * fy + hSE * fx * fy

                    dirX = dirX * p.inertia - gradX * (1 - p.inertia)
                    dirY = dirY * p.inertia - gradY * (1 - p.inertia)
                    let len = (dirX * dirX + dirY * dirY).squareRoot()
                    guard len >= 1e-9 else { break }
                    dirX /= len; dirY /= len
                    let npx = px + dirX, npy = py + dirY
                    guard npx >= 0, npx < Double(n - 1), npy >= 0, npy < Double(n - 1) else { break }

                    let nnx = Int(npx), nny = Int(npy)
                    let nfx = npx - Double(nnx), nfy = npy - Double(nny)
                    let nk = nny * n + nnx
                    let newHeight = ph[nk] * (1 - nfx) * (1 - nfy) + ph[nk + 1] * nfx * (1 - nfy)
                                 + ph[nk + n] * (1 - nfx) * nfy + ph[nk + n + 1] * nfx * nfy
                    let deltaH = newHeight - height

                    let capacity = max(-deltaH, p.minSlope) * speed * water * p.capacity

                    if sediment > capacity || deltaH > 0 {
                        let dep = (deltaH > 0) ? min(deltaH, sediment)
                                               : (sediment - capacity) * p.depositRate
                        sediment -= dep
                        sediment += deposit(k, dep * (1 - fx) * (1 - fy))
                                 +  deposit(k + 1, dep * fx * (1 - fy))
                                 +  deposit(k + n, dep * (1 - fx) * fy)
                                 +  deposit(k + n + 1, dep * fx * fy)
                    } else {
                        let ero = min((capacity - sediment) * p.erodeRate, -deltaH)
                        if ero > 0 {
                            for i in 0..<brushCount {
                                let cx = nodeX + pbx[i], cy = nodeY + pby[i]
                                if cx < 0 || cx >= n || cy < 0 || cy >= n { continue }
                                let ck = cy * n + cx
                                sediment += dig(ck, ero * pbw[i])
                            }
                        }
                    }

                    speed = (max(0, speed * speed - deltaH * p.gravity)).squareRoot()
                    let sv = streamOn ? min(1, max(0, pstream![k])) : 0.0
                    water *= (1 - p.evaporate * (1 - p.streamEvapDamp * sv))
                    px = npx; py = npy
                    if water < 1e-3 { break }
                }
            }
        }}}}}}}}}}}}}}}
    }
}
