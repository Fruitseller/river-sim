# Swift-6-Modus je Target, unsichere Stellen zentral begründet

Die Targets `SimCore`, `SimRender`, `SimPerf` und `SimCoreTests` kompilieren im Swift-6-Modus mit strikter Nebenläufigkeitsprüfung (Issue #201). Der Modus steht je Target (`.swiftLanguageMode(.v6)`), nicht auf Paketebene (`swiftLanguageModes`), weil die Paket-Default-Ebene für alle Targets gleich gilt und der Umstieg Target für Target anstand.

Die unsicheren Stellen sind als `nonisolated(unsafe)` bzw. `@unchecked Sendable` markiert und am Ort begründet:

- Parallele Zeilenschleifen über `DispatchQueue.concurrentPerform` (`ErosionFilter.apply`, `RangeSkeleton.evaluate`): rohe Zeiger gehen in die `@Sendable`-Closure; je Zeile `j` wird nur der eigene, disjunkte Index-Bereich `j * n + i` geschrieben (Projektregel wie bei `Terrain.parallel`). Fertig berechnete Werte (z. B. `peak` in `ErosionFilter.apply`) werden vorher per `let` neu gebunden, damit die Closure keine `var`-Referenz hält.
- Die Feldtabellen des Weltformats (`WorldSnapshot.doubleFields` usw.) sind `nonisolated(unsafe)`, weil `WritableKeyPath` (objc-Klasse) nicht `Sendable` ist und `FieldSpec` ihn führt. Die Tabellen sind unveränderliche `let`-Werte (String, KeyPath, Bool); die Markierung betrifft nur die globale Konstante, nicht die Nutzung.

Betrifft: `SimCore/Package.swift`, `ErosionFilter.apply`, `RangeSkeleton.evaluate`, `WorldSnapshot.doubleFields`, `WorldSnapshot.FieldSpec`, `Terrain.parallel`
