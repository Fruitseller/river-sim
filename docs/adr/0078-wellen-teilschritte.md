# Küstenerosion mit fester Teilschritt-Stärke

`wavePass` ist ein Teilschritt der Küstenerosion mit der Stärke `relax`. Wie viele Teilschritte ein Zeitschritt bekommt, legt `waveSchedule(dt:)` fest: die Stärke eines Teilschritts ist fest (`waveRelax` je 100 Jahre, der kalibrierte Wert), die Anzahl wächst mit dt, aufgerundet `max(1, ⌈dt/100⌉)`. Aufrunden, nicht runden: kein Teilschritt darf stärker werden als der kalibrierte 100-Jahr-Schritt (Stabilität wie subK ≤ 0.2). Damit ist die Gesamtwirkung ∝ dt (Issue #2), wie bei der Hangdiffusion.

Vorher war `wavePass` eine reine Zählschleife (`max(1, min(24, dt/100))`) mit voller Stärke je Durchlauf: ein Zeitraffer-Schritt (dt ≈ 9 J.) bekam die volle 100-Jahr-Relaxation, bis zu 11× zu viel Küstenerosion; ab dt > 2400 sättigte der Deckel 24, große Sprünge erodierten zu wenig. Gemessen (n = 192, 20k J., Seed 1337): Küstenzone 5943 Zellen bei dt = 10 gegen 4314 bei dt = 240. Bei dt = k·100 ist der Takt identisch zu vorher, die Kalibrierung von `waveRelax` bleibt unangetastet.

Kosten: ohne den 24er-Deckel wird ein +10.000-Jahre-Sprung zu 100 Teilschritten statt 24. Das ist die minimale Zahl, mit der die Teilschritt-Stärke unter `waveRelax` bleibt, und der Pass ist ein reiner O(n²)-Scan ohne Nachbarschafts-Suche, die billigste Sorte Pass in `step()`.

Betrifft: `Terrain.wavePass`, `Terrain.waveSchedule`, `SimConfig.waveRelax`
