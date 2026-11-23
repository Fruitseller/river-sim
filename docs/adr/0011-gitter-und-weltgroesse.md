# Gitter 720 / Welt 112,4789: n und world nur gemeinsam ändern

`n` und `world` wurden im August 2026 GEMEINSAM von 832/130 auf 720/112,4789 gesenkt. Die Zellgröße bleibt dabei gleich (112,4789/719 = 0,156438 == 130/831 auf sechs Stellen), alle per-Zell-Kalibrierungen (Braid-Gates, Droplet-Dichte, kappa) gelten unverändert weiter. Was schrumpft, ist die Insel (74,9 % der Fläche), nicht das Detail.

Grund ist Rechenzeit. Gemessen interleaved (simperf, M4 Max, Minimum aus je drei Läufen): 832 → 63,6 ms/Schritt, 720 → 47,6 (1,34×), 640 → 37,6 (1,69×). Die Kosten folgen n² auf 0,1 ms. Sim-Speicher 243 → ~182 MB. 640/100 (die Paarung vor 832/130) war ebenfalls im Vergleich: dort verschwand die Seenkette im Inneren sichtbar, bei 720 bleibt sie, deshalb der Zwischenwert und nicht der schnellere.

Historie der Paarung: 640/100 → 832/130 (Insel ~1,7× größer) → 720/112,4789. Die Zellgröße blieb bei allen dreien ~0,1564; die auf n = 640 kalibrierten Per-Zell-Parameter gelten seit damals unverändert.

Folge für Tests: `world` allein verschiebt die Zellgröße jedes Tests, der nur `n` pinnt. Deshalb pinnen die Testkonfigs seit dieser Umstellung `world` mit (`SimCoreTests/TestCalibration.swift`), und `lakeLevelResponseYears` musste mitgezogen werden (s. ADR zum Darstellungs-Seespiegel).

Randfälle der abgeleiteten Größen (Vertrag):
- `cellSize = world / (n − 1)`. Der Rückgabewert 0 ist der Sentinel für „keine definierte Schrittweite“ und deckt zwei Fälle ab: ungültiges Gitter (`n <= 0`, nicht-positive oder nicht-endliche Welt) und das gültige 1-Punkt-Gitter (`n == 1`), das nur keinen Punktabstand hat. `cellSize == 0` ist deshalb KEIN Ungültig-Gate für die Config; wer durch `cellSize` teilt (z. B. die Pinsel-Iteration in `Terrain`), prüft selbst auf `> 0`.
- `count = n * n`, für `n <= 0` und bei Überlauf defensiv 0 (keine positiven Zellzahlen bei negativem `n`). Anders als bei `cellSize` bleibt `n == 1` gültig: ein 1×1-Gitter hat genau einen Punkt, und die Puffer aus `Terrain(allocating:)` müssen zu `idx(i,j)` über `0..<n` passen.

Betrifft: `SimConfig.n`, `SimConfig.world`, `SimConfig.cellSize`, `SimConfig.count`, `SimCoreTests/TestCalibration.swift`
