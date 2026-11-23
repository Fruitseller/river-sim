# 4-ärer Loch-Heap mit Cache-Zeilen-Ausrichtung für den Priority-Flood

Der Priority-Flood pusht und poppt je Aufruf ~700k Zellen (n=832), ~10 Mio. Sift-Schritte; er war mit 113 der 138 ms von `computeFlow` der dominierende Posten. `MinHeap` arbeitet deshalb auf einem vorallozierten Puffer und vermeidet drei gemessene Kosten:

- Getrennte `keys`/`cells`-Arrays kosteten zwei Cache-Zeilen je Sift-Ebene; jetzt ein gepackter 16-Byte-Eintrag. Der Spaltenindex `col` reist im Padding gratis mit, damit `priorityFlood` je Zelle kein `c % n` braucht (Integer-Division ist bei 700k Zellen je Aufruf messbar).
- `Array`-Subscript/`swapAt` prüft je Zugriff Bounds und COW-Uniqueness, und der Zugriff über die Klassen-Property `Terrain.heap` löste je Push/Pop Exclusivity-Enforcement aus; jetzt läuft der ganze Flood über `withRaw` in einem Roh-Puffer-Zugriff (`MinHeap.Ref`).
- Sift-up/-down swappten (2 Writes je Ebene); jetzt wandert ein „Loch" (1 Write je Ebene), und vier Kinder halbieren gegenüber einem Binär-Heap die Tiefe.

Perf-Runde 3 (`docs/perf-measurements.md` §I), beide ergebnis-neutral:

- Die vier Kinder von `i` liegen auf 4i+1 … 4i+4, also Byte-Offset 64·i+16, und überspannen zwei Cache-Zeilen. Drei Einträge Vorlauf nach dem Ausrichten des Puffer-Anfangs auf 64 Byte schieben sie auf eine Zeile je Ebene; der Pop wandert im Mittel 5,5 Ebenen tief. Die Heap-Indizes ändern sich nicht, nur wo Index 0 liegt; `simperf --hash` unverändert. Die Ausrichtung ist best effort und geht genau dann auf, wenn der Puffer-Anfang auf einem Vielfachen der Eintragsgröße (16 Byte) liegt; Swift legt Array-Speicher mindestens auf 16 Byte, der reale Fall ist also der gute. Dafür `+ 7` Einträge Reserve (bis zu 4 zum Ausrichten, 3 Vorlauf), 112 Byte.
- Die Auswahl des kleinsten Kindes ist ein Turnier statt einer seriellen Abtastung: die vier Keys laden unabhängig, der Vergleichsbaum ist zwei statt drei Ebenen tief. Alle Vergleiche sind strikt (`<`), bei Gleichstand gewinnt der kleinste Index, genau wie „erster mit minimalem Key"; die Pop-Reihenfolge ist unverändert.

Die Loch-Variante hat dieselbe Min-Heap-Semantik wie eine Swap-Variante. Unter gleichen Keys darf die 4-äre Struktur Zellen in anderer, aber deterministischer Reihenfolge ausgeben; Priority-Flood braucht für seine Korrektheit nur die nicht fallende Key-Reihenfolge.

Betrifft: `MinHeap`, `MinHeap.Entry`, `MinHeap.Ref`, `MinHeap.withRaw`, `Terrain.priorityFlood`
