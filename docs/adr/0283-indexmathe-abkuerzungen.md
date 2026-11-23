# Index-Abkürzungen: Diagonalität aus der Index-Differenz, Rundung wie `rounded()`

`outletIncision` entscheidet „diagonaler Schritt?" über die Index-Differenz statt über zwei i/j-Paare und spart zwei Integer-Divisionen je Zelle (#43). Das ist nur zulässig, weil der Empfänger immer einer der acht Nachbarn ist; für jeden 8-Nachbarn inklusive aller Randlagen muss `|k − r| ∈ {n−1, n+1}` genau dann gelten, wenn sich Spalte und Zeile ändern. Ein Fehler wäre keine Perf-Regression, sondern eine falsche Distanz in der Stream-Power, also eine andere Welt.

`Terrain.cellIndex` und `Terrain.gridRound` müssen auf beiden Achsen exakt dieselbe Zelle wählen wie die historische Referenz `Int(coord.rounded())` (round-half-away-from-zero; PR #219, Bot-Finding). Kritisch ist `0.5.nextDown`: eine naive Addition `x + 0.5` rundet wegen Round-to-Nearest-Even auf 1.0 und wählt Zelle 1 statt 0. Geprüft werden alle Halben von −100 bis +1000 samt Vorgänger und Nachfolger, im Kreuzprodukt beider Achsen.

Betrifft: `Terrain.outletIncision`, `Terrain.cellIndex`, `Terrain.gridRound`, `IndexMathTests`
