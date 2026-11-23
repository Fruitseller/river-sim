# Datenparallelität nur über disjunkte Bereiche, ein zentraler unsafe-Engpass

`Terrain.parallel(count, body)` führt `body(lo, hi)` über disjunkte Indexbereiche aus, nur für Pässe, deren Zellen unabhängig sind (jede schreibt ausschließlich ihren eigenen Index). Das Ergebnis ist bit-identisch zur sequenziellen Schleife. Es gibt mehr Chunks als Kerne (Kerne × 4), damit `concurrentPerform` ungleich schnelle P- und E-Kerne auslastet.

Swift 6 (Issue #201): `concurrentPerform` verlangt eine `@Sendable`-Closure, die Aufrufer erfassen aber bewusst rohe Zeiger (die Roh-Puffer-Sicht `Terrain.Bed` ist die Hot-Loop-Form) und `self`. Die Disjunktheit sieht der Compiler nicht; sie ist Projektregel und wird von den Bit-Identitäts-Wächtern geprüft (u. a. `BeltParallelTests`). Deshalb steht genau eine `nonisolated(unsafe)`-Erfassung hier statt verstreut an den Aufrufern; die Signatur bleibt nicht-`@Sendable`, die Aufrufstellen bleiben unverändert. Wer ein Rennen einbaut, baut es durch diesen Engpass.

Betrifft: `Terrain.parallel`, `Terrain.coreCount`, `Terrain.Bed`
