# Strahler-Ordnung auf dem D8-Empfänger-Wald

Für die Rang-Hierarchie der Fluss-Bänder (Issue #31) wird die Strahler-Ordnung auf dem D8-Netz berechnet, nicht auf MFD: sie braucht den Empfänger-Baum. Sie ist eine reine Render-/Rang-Ableitung ohne Sim-Zustand und wird nicht persistiert (nicht im Zustandsinventar von `Terrain.swift`).

Semantik: Netz ist die Menge der Zellen mit `isNetwork` (typisch Einzugsgebiet über einer Kanal-Schwelle); alles außerhalb bekommt Ordnung 0 und zählt nicht als Donor. Netz-Quelle = 1; Zusammenfluss zweier oder mehr Stränge gleicher Maximal-Ordnung s → s+1, sonst bleibt die Maximal-Ordnung.

Randfall bewusst so belassen: eine Netz-Lücke (Netz → Nicht-Netz → Netz, etwa über eine Meerzelle) trennt die Stränge. Stromab der Lücke beginnt die Ordnung wieder bei 1; der Rang springt nicht über Nicht-Netz-Zellen.

Die Berechnung läuft als Kahn-Topsort über den Donor-Grad. Das Ergebnis ist eindeutig, unabhängig von der Abarbeitungs-Reihenfolge, also deterministisch. Empfänger-Indizes außerhalb des Gitters werden wie Senken behandelt.

Betrifft: `Strahler.orders`, `Terrain.strahlerOrders`
