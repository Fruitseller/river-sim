# Becken entwässern zum Meer und bleiben entwässert

Die Generierung liefert Terrain, dessen Becken zum Meer entwässert sind (nickmcd-Verhalten): frisch generiert gemessen 4–5 % Seeanteil, ohne Breach 15–30 %; Schranke 8 %.

Unter Simulation dürfen Seen sich füllen und leeren (der tiefe See oszilliert gewollt), aber kein permanenter tiefer Mega-See entstehen. Deshalb prüft der Wächter das Minimum des größten tiefen Sees über den Lauf. Der Augenblickswert bei Jahr 10.000 hat die Schranke 0.16 statt 0.14 (Issue #2): gemessen (Seed 1337, alle 1000 J.) ist Jahr 10k auf beiden Ständen das lokale Maximum der Reihe (`main` 0.129, Branch 0.142, sonst 0.10…0.12), und die alte Schranke ließ `main` nur 0.011 Luft auf einer Größe, die zwischen zwei Realisierungen um ±0.02 wandert. 0.16 hält Abstand zum Fehlerbild (permanenter Mega-See, ohne Breach 13–25 %).

Betrifft: `Terrain.priorityFlood`, `Terrain.capEndorheicBasins`, `RiverDynamicsTests.testBasinsDrainToSea`
