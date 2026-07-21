import Foundation

/// Binärer Min-Heap über (key, cell), für Priority-Flood. Arbeitet auf
/// vorallozierten Arrays, um GC-Druck im Sim-Loop zu vermeiden.
struct MinHeap {
    private var keys: [Double]
    private var cells: [Int32]
    private(set) var size = 0

    init(capacity: Int) {
        keys = [Double](repeating: 0, count: capacity)
        cells = [Int32](repeating: 0, count: capacity)
    }

    mutating func removeAll() { size = 0 }
    var isEmpty: Bool { size == 0 }

    mutating func push(key: Double, cell: Int32) {
        var i = size
        keys[i] = key
        cells[i] = cell
        size += 1
        while i > 0 {
            let p = (i - 1) >> 1
            if keys[p] <= keys[i] { break }
            keys.swapAt(p, i)
            cells.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> Int32 {
        let top = cells[0]
        size -= 1
        keys[0] = keys[size]
        cells[0] = cells[size]
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < size && keys[l] < keys[m] { m = l }
            if r < size && keys[r] < keys[m] { m = r }
            if m == i { break }
            keys.swapAt(m, i)
            cells.swapAt(m, i)
            i = m
        }
        return top
    }
}
