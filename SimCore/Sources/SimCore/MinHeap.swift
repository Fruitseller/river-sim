import Foundation

struct MinHeap {
    struct Entry {
        var key: Double
        var cell: Int32
        var col: Int32
    }

    struct Ref {
        let b: UnsafeMutablePointer<Entry>
        var size: Int
        var isEmpty: Bool { size == 0 }

        @inline(__always) mutating func push(key: Double, cell: Int32, col: Int32) {
            var i = size
            size = i + 1
            while i > 0 {
                let parent = (i - 1) >> 2
                if b[parent].key <= key { break }
                b[i] = b[parent]
                i = parent
            }
            b[i] = Entry(key: key, cell: cell, col: col)
        }

        @inline(__always) mutating func pop() -> Entry {
            let top = b[0]
            size -= 1
            let last = b[size]
            var i = 0
            while true {
                let firstChild = 4 * i + 1
                if firstChild >= size { break }
                var child: Int
                var childKey: Double
                if firstChild + 4 <= size {
                    let k0 = b[firstChild].key, k1 = b[firstChild + 1].key
                    let k2 = b[firstChild + 2].key, k3 = b[firstChild + 3].key
                    let lo01 = k1 < k0
                    let i01 = lo01 ? firstChild + 1 : firstChild
                    let k01 = lo01 ? k1 : k0
                    let lo23 = k3 < k2
                    let i23 = lo23 ? firstChild + 3 : firstChild + 2
                    let k23 = lo23 ? k3 : k2
                    let takeHigh = k23 < k01
                    child = takeHigh ? i23 : i01
                    childKey = takeHigh ? k23 : k01
                } else {
                    child = firstChild
                    childKey = b[firstChild].key
                    var candidate = firstChild + 1
                    while candidate < size {
                        if b[candidate].key < childKey {
                            child = candidate
                            childKey = b[candidate].key
                        }
                        candidate += 1
                    }
                }
                if last.key <= childKey { break }
                b[i] = b[child]
                i = child
            }
            b[i] = last
            return top
        }
    }

    private var storage: [Entry]
    private(set) var size = 0

    init(capacity: Int) {
        storage = [Entry](repeating: Entry(key: 0, cell: 0, col: 0),
                          count: max(1, capacity) + 7)
    }

    mutating func removeAll() { size = 0 }
    var isEmpty: Bool { size == 0 }

    mutating func withRaw<R>(_ body: (inout Ref) -> R) -> R {
        let start = size
        var end = size
        var result: R?
        storage.withUnsafeMutableBufferPointer { p in
            let raw = UInt(bitPattern: p.baseAddress!)
            let stride = MemoryLayout<Entry>.stride
            let pad = (Int((64 &- (raw & 63)) & 63) + stride - 1) / stride
            var ref = Ref(b: p.baseAddress! + pad + 3, size: start)
            result = body(&ref)
            end = ref.size
        }
        size = end
        return result!
    }
}
