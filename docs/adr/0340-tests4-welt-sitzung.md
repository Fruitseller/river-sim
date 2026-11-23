# Welt-Sitzung: Brückenregel ausführbar geprüft

Die Regel der Brücke ist seit Issue #212 in `WorldSession` ausführbar geprüft statt per Quelltext-Grep; bis dahin stand sie an jeder Methode von `SimNode` und war nur in CI geprüft. Zusicherungen: jede Weltänderung meldet die passende `TerrainChange` und danach liefert der Render-Zustand den frischen Stand; ein laufender Hintergrund-Schritt wird vor jedem Lese- und Schreibzugriff abgewartet; höchstens ein Schritt ist unterwegs; Hintergrund-Schritte sind bit-gleich zu synchronen.

Die Änderungsart ist nicht beliebig (Issue #167): ein Pinsel als `.advanced` ließe veralteten Wald stehen, ein Sim-Schritt als `.edited` schaltete das Gedächtnis der Waldmaske ab. Solange ein Schritt unterwegs ist (auch fertig, aber nicht abgeholt), startet `beginStep` nichts, sonst ginge der liegende Frame verloren.

Gibt der Knoten die Sitzung frei, während ein Schritt rechnet, kehrt die Freigabe erst zurück, wenn der Schritt fertig ist: danach entlädt Godot beim Beenden die Library, deren Code der Job ausführt. Bis #212 stand diese Schranke als `SimNode.deinit`; sie trägt nur, solange der Job die Sitzung nicht selbst hält (Review #216).

Prüfweise: die Abwarte-Tests sind deterministisch, ohne Zeitfenster. Der Job hält an einer Schranke, die erst der Zugriff selbst unmittelbar vor dem Blockieren öffnet (`stepWillBlock`); ohne Abwarten öffnet sie niemand und `stepWaits` bleibt 0. Die Hilfskästen sind `@unchecked Sendable`, weil Semaphoren alle Zugriffe ordnen. Die Overlays muss der Frame liefern; ein Ersatzwert (`?? []`) ließe einen ausgebliebenen Material-Upload als grünen Test durchgehen.

Betrifft: `WorldSession`, `BackgroundJob`, `TerrainChange`, `SimNode`, `WorldSessionTests`
