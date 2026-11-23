# Nebenläufigkeit über disjunkte Fenster, unsichere Markierung zentral

Parallele Pässe in `Terrain.swift` teilen Roh-Zeiger über Thread-Grenzen. Unter Swift 6 (Issue #201) sind diese Zeiger und der nicht-`Sendable` Sim-Zustand an je EINER zentralen Erfassungsstelle als `nonisolated(unsafe)` markiert bzw. der Scheduler als `@unchecked Sendable`, nicht an jeder Lesestelle. Die Sicherheit kommt aus der Projektregel disjunkter Index-Bereiche (s. `Terrain.parallel`), nicht aus dem Typsystem; die Bit-Identitäts-Wächter prüfen sie.

Die Fälle:
- `deltaHeightSum`: jeder Block schreibt nur `ps[c]`/`pl[c]`/`pout[c]` mit seinem eigenen `c` und liest sonst nur. Ob die Mündungsliste gefüllt wird, entscheidet der Schalter `collectMouths`, nicht der Zeiger: bei leerem Feld ist `baseAddress` nicht sicher `nil`.
- `drainageSegments`: die Abschnitte sind nach Quellen disjunkt und lesen nur `h`, `hf`, `area`, `receiver`; geschrieben wird nur `pf[ch]` je Block. Quellen und Abschnitte laufen in Blöcken (auf `coreCount` geklemmt statt 64 Tasks), das Zusammenfügen in Block-Reihenfolge ist bit-identisch zur seriellen Schleife.
- `coupleBeltToDrainage`, Zuordnung der alten Knoten: je Lauf ein disjunktes Intervall der flachen Puffer, geschrieben wird nur `[base + i]` des eigenen Laufs; die Offset-Tabelle ist vorher gefüllt und wird nur gelesen (der let-Rebind nimmt der Closure die var-Referenz).
- `parallelBeltRuns` / `BeltSchedule`: Abhängigkeitsgraph der Gürtel-Läufe. Für jedes überlappende Paar i < j bleibt die Reihenfolge erhalten, gleichzeitig arbeiten nur vollständig unabhängige Läufe; ein Lauf wartet nur auf seine überlappenden Vorgänger, nicht auf unabhängige langsame Läufe derselben Ebene. Gemeinsame Arrays sind währenddessen nur als Roh-Puffer offen, jeder Arbeiter besitzt seinen eigenen Cutoff-Index und seine Historie. `BeltSchedule` IST der Parallelstart und wird von allen Workern gleichzeitig benutzt; jeder Warteschlangen-Zugriff steht unter dem Condition-Lock, Sim-Zustand fasst der Scheduler nie an. Der Compiler kann das nicht prüfen (`waiting`/`ready` sind veränderlich), daher `@unchecked Sendable` statt Umbau. `work` erfasst absichtlich nicht-`Sendable` Sim-Zustand; die Exklusivität kommt vom Graphen.
- `beltStampChannel`: der Aufrufer garantiert disjunkte Lese- UND Schreibfenster aller gleichzeitig laufenden Stempel.

Wer Nebenläufigkeit ändert, ändert diese Engpässe und hält die Disjunktheit ein.

Betrifft: `Terrain.parallel`, `Terrain.deltaHeightSum`, `Terrain.drainageSegments`, `Terrain.coupleBeltToDrainage`, `Terrain.parallelBeltRuns`, `Terrain.BeltSchedule`, `Terrain.beltStampChannel`
