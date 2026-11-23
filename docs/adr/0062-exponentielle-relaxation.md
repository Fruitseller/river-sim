# Verlandungen relaxieren exponentiell statt linear gedeckelt

Verlandungs-Pässe nähern eine Höhe mit einer Zeitkonstante τ an. Seit Issue #2 nehmen sie je Schritt den Anteil `1 − e^(−dt/τ)` (`Terrain.relaxFraction`), nicht `min(0.5, dt/τ)` oder `min(1, dt/τ)`. Nur die exponentielle Form teleskopiert über beliebig viele Teilschritte exakt zum Ergebnis eines Sprungs (wie `relaxWaterLevel`); Zeitraffer und Sprung landen am selben Stand.

Gemessene Fehler der linearen Formen:
- `fillShallowPonds`: mit `puddleFillYears = 800` deckelte `min(0.5, dt/τ)` schon ab dt = 400 und ließ große Schritte systematisch zu viel Ponding stehen; Zeitraffer und Sprung verlandeten unterschiedlich schnell.
- `fillOxbows`: `min(1, dt/τ)` verlandete einen 5500-Jahr-Sprung komplett in einem Schritt, dieselbe Zeit in kleinen Schritten dagegen nur zu 63 % (1 − 1/e).
- `fillLakes` (τ ≈ 3000 Jahre) und `floodplainAggradation` folgen derselben Form. Beide sind geparkt (`basinFill = false`, `floodplainEnabled = false`), sollen aber nicht mit einer bekannt dt-abhängigen Relaxation als Referenz liegen bleiben.

Betrifft: `Terrain.relaxFraction`, `Terrain.fillLakes`, `Terrain.fillShallowPonds`, `Terrain.fillOxbows`, `Terrain.floodplainAggradation`, `docs/dt-invariance-measurements.md`
