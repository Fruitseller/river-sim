# Performance nur bit-identisch: disjunkte Parallelität, Roh-Puffer, Vorab-Rechnung

Gleicher Seed heißt bit-gleiches Ergebnis auf derselben Maschine; das ist eine getestete Invariante, und ein verlorenes ulp divergiert über das chaotische System messbar. Die Perf-Arbeit am Sim-Schritt (Issue #43 und Folgerunden) folgt deshalb vier Regeln, die zusammen gelten.

Parallel nur über disjunkte Indexbereiche: `Terrain.parallel(count, body)` führt `body(lo, hi)` über disjunkte Bereiche aus, nur für Pässe, deren Zellen ausschließlich ihren eigenen Index schreiben. Das Ergebnis ist bit-identisch zur sequenziellen Schleife. Es gibt mehr Chunks als Kerne (Kerne × 4), damit `concurrentPerform` ungleich schnelle P- und E-Kerne auslastet.

Ein zentraler unsafe-Engpass (Swift 6, Issue #201): `concurrentPerform` verlangt eine `@Sendable`-Closure, die Aufrufer erfassen aber bewusst rohe Zeiger und `self`. Die Disjunktheit sieht der Compiler nicht; sie ist Projektregel und wird von den Bit-Identitäts-Wächtern geprüft (u. a. `BeltParallelTests`). Deshalb steht genau eine `nonisolated(unsafe)`-Erfassung an den Parallel-Helfern statt verstreut an den Aufrufstellen; deren Signatur bleibt nicht-`@Sendable`. Wer ein Rennen einbaut, baut es durch diesen Engpass.

Heiße Pässe auf Roh-Puffern: über die Klassen-Property zahlt jeder Zugriff Bounds-, COW- und Exklusivitäts-Prüfung (`swift_beginAccess`/`AccessSet::insert`), bei n = 832 gemessen ~40 Zyklen je Zugriff; eine Schleife über zwei oder mehr Property-Felder kostete ~9 ms je Feld und Schritt. Die Pässe öffnen ihre Felder deshalb einmal als Roh-Puffer (`withUnsafe…BufferPointer`, das Bett über `withBed`) und rechnen darauf mit unveränderten Werten, Reihenfolgen und Vergleichen. Beispiel `applyUplift`: 26,6 → 2,4 ms je Schritt.

Vorab parallel nur, was der Pass nicht schreibt: was sich während eines Passes nicht ändert, wird vorab und parallel gerechnet, die serielle Schleife liest es nur nach. Erlaubt ist das nur für Größen, deren Operanden der Pass nicht schreibt, und für reine `continue`-Filter, deren Ergebnis von der Prüfreihenfolge unabhängig ist. Alles, was frisches `h` liest, bleibt im seriellen Loop. Beispiel `outletIncision`: ein libm-`pow` je Zelle kostete ~16 ms je Schritt; `area` ändert sich im Pass nicht, also läuft die Potenz vorab parallel, mit denselben Aufrufen und Argumenten.

Nachweis: jede Umstellung ist bit-identisch zur Vorfassung, belegt mit `simperf --hash` vor und nach der Änderung auf derselben Maschine (Fingerabdruck über das komplette Zustands-Inventar, ADR 0006). Dazu gilt die Regel aus AGENTS.md: keine Perf-Änderung ohne gemessenes Vorher/Nachher.

Verworfen:
- `@Sendable`-Signatur mit unsafe-Markierung an jeder der rund 56 Aufrufstellen: dieselbe Begründung verstreut statt an einem Engpass.
- Beschleunigungen, die eine Reihenfolge ändern, auch wenn sie „gleichwertig" aussehen: Priority-Flood mit FIFO (Barnes et al.) und ein 8-ärer oder cache-ausgerichteter Heap ändern das Tie-Break gleicher Füllhöhen, damit `order`, die Summationsreihenfolge der Flächen-Akkumulation und die Rundung. Das ist eine andere Welt, keine schnellere.

Pass-Zahlen und Einzelfälle: `docs/perf-measurements.md` §C, §I, §S und „Einzelfälle der Roh-Puffer-Umstellung".

Betrifft: `Terrain.parallel`, `Terrain.coreCount`, `Terrain.Bed`, `Terrain.withBed`, `parallelChunks`, `Terrain.fingerprint`, `SimCore/Sources/SimPerf/main.swift`
