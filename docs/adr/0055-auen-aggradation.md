# Auen-Aggradation hebt nur Nicht-Kanal-Zellen an

`floodplainAggradation` (geparkt, `floodplainEnabled = false`) baut flache Auenböden: für jede Fluss-Zelle mit großem Einzugsgebiet werden tal-nahe TIEFERE Zellen mit Sediment bis knapp über das Bett-Niveau (bankfull, ∝ log Abfluss) aufgefüllt. Ohne breite Niedrig-Gradient-Reaches waren die gecarvten V-Täler zu schmal zum Mäandern oder Verflechten (gemessen: nur ~1500 Zellen größte zusammenhängende Aue). Nur Zellen unter `Bett + Auenhöhe` werden gefüllt, Talwände und Berge bleiben unberührt; deposition-only und gedeckelt, also konvergent.

Stabilität: die Kanalzellen sind die Referenz und werden NIE angehoben, nur Nicht-Kanal-Zellen. Sonst pumpen sich auf flachen Reaches benachbarte Kanalzellen (Slope < depth) gegenseitig hoch (A hebt B auf A+depth, B hebt A auf B+depth), ein Runaway (gemessen: maxH 0.95 → 10.7). Weil Nicht-Kanal-Zellen nichts anheben, gibt es keine Rückkopplung; jede Auenzelle konvergiert gegen max(Kanalbett + Auenhöhe) in ihrer Nähe.

Im Schritt steht der Pass nach dem Carve (das Bett steht) und vor der Diffusion (die die Aue glättet).

Betrifft: `Terrain.floodplainAggradation`, `SimConfig.floodplainEnabled`, `Terrain.step`
