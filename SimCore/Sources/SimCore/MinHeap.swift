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
/// Perf-Runde 3 hat zwei weitere Posten geholt, beide ergebnis-neutral
/// (`docs/perf-measurements.md` §I): die Kindergruppe liegt jetzt auf EINER
/// Cache-Zeile (Vorlauf in `withRaw`), und die Auswahl des kleinsten Kindes ist
/// ein Turnier statt einer seriellen Abtastung (`pop`).
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
                var child: Int
                var childKey: Double
                if firstChild + 4 <= size {
                    // Volle Vierergruppe (nach der Ausrichtung in `withRaw`
                    // genau EINE Cache-Zeile): Turnier statt serieller
                    // Abtastung. Die vier Keys laden unabhängig voneinander und
                    // der Vergleichsbaum ist zwei statt drei Ebenen tief — die
                    // Abtastung war eine reine Abhängigkeitskette.
                    //
                    // Bei GLEICHSTAND gewinnt weiterhin der KLEINSTE Index: alle
                    // Vergleiche sind strikt (`<`), also setzt sich in jedem
                    // Paar und im Finale der frühere durch — genau das Ergebnis
                    // der Abtastung „erster mit minimalem Key". Die
                    // Pop-Reihenfolge ist damit unverändert.
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

    /// `+ 7` Reserve: bis zu 4 Einträge, um den Puffer-Anfang auf 64 Byte zu
    /// bringen, plus die 3 Einträge Vorlauf der Ausrichtung (s. `withRaw`).
    /// Sie kosten 112 Byte und nichts an Laufzeit.
    init(capacity: Int) {
        storage = [Entry](repeating: Entry(key: 0, cell: 0, col: 0),
                          count: max(1, capacity) + 7)
    }

    mutating func removeAll() { size = 0 }
    var isEmpty: Bool { size == 0 }

    /// Öffnet den Puffer EINMAL für einen kompletten Flood-Durchlauf.
    mutating func withRaw<R>(_ body: (inout Ref) -> R) -> R {
        let start = size
        var end = size
        var result: R?
        storage.withUnsafeMutableBufferPointer { p in
            // PERF: die vier Kinder eines Knotens `i` liegen auf 4i+1 … 4i+4,
            // also auf Byte-Offset 64·i+16 — sie überspannen damit bei jedem
            // Sift-Schritt ZWEI Cache-Zeilen. Drei Einträge Vorlauf (nach dem
            // Ausrichten des Puffer-Anfangs auf 64 Byte) schieben sie auf
            // 64·i+64, also auf EINE Zeile je Ebene, und der Pop wandert im
            // Mittel 5,5 Ebenen tief (gemessen, docs/perf-measurements.md).
            //
            // Die Heap-INDIZES ändern sich dabei nicht, nur wo Index 0 im
            // Speicher liegt. Struktur, Vergleiche und damit die Pop-Reihenfolge
            // bei GLEICHEN Keys bleiben exakt dieselben — die Verschiebung ist
            // ergebnis-neutral (`simperf --hash` unverändert).
            //
            // Die Ausrichtung ist BEST EFFORT und die Korrektheit hängt nicht an
            // ihr, nur die Zahl der berührten Cache-Zeilen. Sie geht genau dann
            // auf, wenn der Puffer-Anfang schon auf einem Vielfachen der
            // EINTRAGSGRÖSSE (16 Byte) liegt: ein Versatz um ganze Einträge
            // ändert `raw % 16` nicht, ein 8-Byte-Anfang bliebe also bei jedem
            // Vorlauf um 8 Byte neben der Zeile. `Entry` verlangt nur 8 Byte
            // Ausrichtung, Swift legt Array-Speicher aber mindestens auf 16 Byte
            // — der reale Fall ist also der gute. Aufgerundet wird, damit der
            // Versatz die Grenze nie unterschreitet.
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
