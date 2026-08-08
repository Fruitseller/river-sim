import Foundation

/// 4-ärer Min-Heap für den Priority-Flood. Arbeitet auf einem vorallozierten
/// Puffer, um GC-Druck im Sim-Loop zu vermeiden.
///
/// PERF: der Flood pusht und poppt je Aufruf ~700k Zellen (n=832) → ~10M
/// Sift-Schritte; er war mit 113 der 138 ms von `computeFlow` der dominierende
/// Posten. Drei Dinge kosteten dort, alle behoben:
/// - getrennte `keys`/`cells`-Arrays = zwei Cache-Zeilen je Sift-Ebene → jetzt
///   EIN gepackter 16-Byte-Eintrag,
/// - `Array`-Subscript/`swapAt` prüft je Zugriff Bounds UND COW-Uniqueness, und
///   der Zugriff über die Klassen-Property `Terrain.heap` löst je Push/Pop
///   Exclusivity-Enforcement aus → jetzt läuft der ganze Flood über `withRaw`
///   in EINEM Roh-Puffer-Zugriff (`MinHeap.Ref`),
/// - Sift-up/-down swappten (2 Writes je Ebene) → jetzt wandert ein „Loch"
///   (1 Write je Ebene), und vier Kinder halbieren gegenüber einem Binär-Heap
///   die Tiefe und damit die Zahl der zufälligen Speicherzugriffe beim Push.
///
/// Die Loch-Variante erhält dieselbe Min-Heap-Semantik wie eine Swap-Variante.
/// Unter gleichen Keys darf die 4-äre Struktur Zellen in einer anderen, aber
/// weiterhin deterministischen Reihenfolge ausgeben; Priority-Flood benötigt
/// für seine Korrektheit nur die nicht fallende Key-Reihenfolge.
struct MinHeap {
    /// key + cell + col in 16 Byte: der Spaltenindex `col` reist im Padding
    /// gratis mit, damit `priorityFlood` je Zelle kein `c % n` braucht
    /// (Integer-Division ist bei 700k Zellen/Aufruf messbar).
    struct Entry {
        var key: Double
        var cell: Int32
        var col: Int32
    }

    /// Roh-Sicht auf den Puffer — hier lebt die eigentliche Heap-Logik.
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
                var child = firstChild
                var childKey = b[firstChild].key
                let childrenEnd = min(firstChild + 4, size)
                var candidate = firstChild + 1
                while candidate < childrenEnd {
                    if b[candidate].key < childKey {
                        child = candidate
                        childKey = b[candidate].key
                    }
                    candidate += 1
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
                          count: max(1, capacity))
    }

    mutating func removeAll() { size = 0 }
    var isEmpty: Bool { size == 0 }

    /// Öffnet den Puffer EINMAL für einen kompletten Flood-Durchlauf.
    mutating func withRaw<R>(_ body: (inout Ref) -> R) -> R {
        let start = size
        var end = size
        var result: R?
        storage.withUnsafeMutableBufferPointer { p in
            var ref = Ref(b: p.baseAddress!, size: start)
            result = body(&ref)
            end = ref.size
        }
        size = end
        return result!
    }
}
