import Foundation

public enum Strahler {
    public static func orders(receiver: [Int32], isNetwork: [Bool]) -> [Int32] {
        let n = receiver.count
        guard isNetwork.count == n else {
            assertionFailure("Strahler.orders: isNetwork.count (\(isNetwork.count)) must match receiver.count (\(n))")
            return [Int32](repeating: 0, count: n)
        }
        guard n > 0 else { return [] }
        var out = [Int32](repeating: 0, count: n)
        var pending = [Int32](repeating: 0, count: n)
        for k in 0..<n where isNetwork[k] {
            let r = Int(receiver[k])
            if r >= 0 && r < n { pending[r] += 1 }
        }
        var maxDonor = [Int32](repeating: 0, count: n)
        var maxCount = [Int32](repeating: 0, count: n)
        var queue = [Int32]()
        queue.reserveCapacity(n)
        for k in 0..<n where isNetwork[k] && pending[k] == 0 { queue.append(Int32(k)) }
        var qi = 0
        while qi < queue.count {
            let k = Int(queue[qi]); qi += 1
            let s: Int32 = maxDonor[k] == 0 ? 1 : (maxCount[k] >= 2 ? maxDonor[k] + 1 : maxDonor[k])
            out[k] = s
            let r = Int(receiver[k])
            guard r >= 0 && r < n else { continue }
            if s > maxDonor[r] { maxDonor[r] = s; maxCount[r] = 1 }
            else if s == maxDonor[r] { maxCount[r] += 1 }
            if isNetwork[r] {
                pending[r] -= 1
                if pending[r] == 0 { queue.append(Int32(r)) }
            }
        }
        return out
    }
}

extension Terrain {
    public func strahlerOrders(minCells: Double) -> [Int32] {
        let n = area.count
        guard receiver.count == n && hf.count == n else {
            assertionFailure("Terrain.strahlerOrders: buffer length mismatch (area=\(n), receiver=\(receiver.count), hf=\(hf.count))")
            return []
        }
        guard n > 0 else { return [] }
        guard minCells.isFinite && minCells > 0 else {
            return [Int32](repeating: 0, count: n)
        }
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else {
            return [Int32](repeating: 0, count: n)
        }
        var net = [Bool](repeating: false, count: n)
        for k in 0..<n {
            net[k] = hf[k] > cfg.sea && area[k] / cellArea >= minCells
        }
        return Strahler.orders(receiver: receiver, isNetwork: net)
    }
}
