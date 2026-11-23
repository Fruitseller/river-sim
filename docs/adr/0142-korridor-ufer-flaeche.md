# Sichtbare Geländehöhe am Ufer nur über `BankSurface`

Wie hoch die sichtbare Geländefläche am Ufer liegt (Welt-Y), fragt der Korridor an GENAU einer Stelle: `BankSurface`. Heute ist das die Triangulierung des Render-Gitters über der Sim-Höhe (`renderSurfaceHeight`), dieselbe Fläche, auf die das Band seine Kanten legt. Ändert sich die sichtbare Fläche (Gelände-Verfeinerung, Strang D, #238), ändert sich nur `BankSurface`.

Die Relief-Verschiebung fehlt bewusst: die Schutzmaske (`WaterProtectMask`: Band-Deckung bis Halbbreite + 0,5 plus `WaterRender.protectSeamCells` Saum) nimmt sie um jedes Band heraus. Der Fuß des Korridors bleibt deshalb innerhalb dieser Maske, mit `CorridorProfile.maskMarginCells` (0,25 Zellen) Abstand davor (`maxReachCells`). Dort ist das Gelände unverschoben: kein Relief, und die Gelände-Verfeinerung aus #238 sagt dort exakt null Abweichung zu. `BankSurface` gilt damit am ganzen Korridor. Wer die Reichweite des Korridors über die Schutzmaske hinaus erweitert oder der Verfeinerung Abweichung in der Maske erlaubt, bricht diese Annahme.

Betrifft: `BankSurface`, `CorridorProfile.maskMarginCells`, `CorridorProfile.maxReachCells`, `WaterProtectMask`, `WaterRender.protectSeamCells`, `scripts/TerrainAmplifier.gd`
