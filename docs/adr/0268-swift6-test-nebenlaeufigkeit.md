# Swift 6 in Tests: Sendable-Tabellen und nonisolated(unsafe) nur mit Begründung

Seit #201 kompiliert `SimCoreTests` im Swift-6-Modus. Zwei Stellen in den Tests umgehen die strikte Prüfung bewusst:

- Die Aufruf-Tabelle der Funnel-Tests (`CallShape`) ist `Sendable`: die statischen Einträge sind globales `let`, die Closures sind zustandslos (`@Sendable`, sie rufen nur Methoden ihres Arguments). Die Konformität ist vollständig vom Compiler geprüft, keine `@unchecked`-Ausnahme.
- Der Wächter des Gürtel-Zeitplans hält zwei Mengen als `nonisolated(unsafe)`: beide werden ausschließlich unter dem Lock gelesen und geschrieben. Der Test prüft gerade die Disziplin, die der Compiler nicht sehen kann.

Betrifft: `BedFunnelTests.CallShape`, `BeltParallelTests`, `Terrain.BeltSchedule`
