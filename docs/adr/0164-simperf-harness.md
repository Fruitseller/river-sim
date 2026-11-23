# Mess-Harness `simperf`: Produktions-Config, eigener Einlauf

`simperf` (Issue #43) fährt headless den benannten Wert `SimConfig.production` selbst (Issue #97), keinen Nachbau seiner Schalter. Der Nachbau war nötig, solange die Konfiguration in der unerreichbaren Extension stand, und trug das Risiko, still gegen die Produktion zu driften, während Kopfzeile und `--hash` behaupten, sie zu spiegeln.

Auch die Gitter-Paarung kommt aus der Produktions-Config, nicht aus einem Literal: sie wurde schon einmal gemeinsam verstellt (832/130 → 720/112,4789, Aug 2026), und als Literal hätte der Harness danach still die alte, größere Welt gemessen. `n` und `world` gehören zusammen; `--n` allein ändert die Zellgröße und jede per-Zell-Kalibrierung, der Lauf misst dann eine andere Physik. Ältere Messreihen in `docs/perf-measurements.md` reproduziert man mit beiden Schaltern (`--n 832 --world 130`). Genau einen der beiden zu setzen ist nie Absicht, sondern eine halbe Umstellung, deren Kopfzeile plausibel aussieht; der Harness bricht deshalb hart ab.

`Terrain(config:seed:)` generiert bereits. Ein zusätzlicher `generate`-Aufruf war nicht nur doppelte Arbeit, sondern verstellte die Messwelt: `generate` leert `veg` nicht, und die Sukzession liest über den Samen-Druck (`vegDispersalRadius`) das vorhandene Feld. Der zweite Lauf startete mit dem Samen-Druck des ersten (gepinnt in `TerrainAPITests.testGenerateResetsAnAgedTerrain`); `veg` ist über `vegDamp` an die Erosion gekoppelt, also nicht bloß Optik.

Bewusste Abweichung von der Produktion: die Brücke generiert mit `settleYears: SimConfig.productionSettleYears` (3000 J. in 1000-Jahr-Chunks, Uhr danach auf 0, dann die Startzustands-Doktrinen für Seespiegel und Playa-Kruste, PR #106). Der Harness lässt `settleYears` bei 0 und läuft über `--warmup` ein (100 × 100 J. = 10.000 Jahre, weiter eingeschwungen als die Produktionswelt). Den Wert zu spiegeln, würde die Messwelt verschieben und jede Zahl in `docs/perf-measurements.md` samt `--hash` ein weiteres Mal unvergleichbar machen; für Vorher/Nachher auf derselben Maschine zählt nur, dass beide Läufe dieselbe Welt fahren. Folge: ein Fingerabdruck aus `--hash` und einer aus der Brücke gehören zu zwei Welten und sind nie gleich.

`--hash` ist der Wächter für „Physik unverändert": `Terrain.fingerprint()` über das komplette Zustands-Inventar (Issue #78; Semantik an `TerrainState.fingerprint()`). Gleicher Wert vor und nach einer Optimierung heißt ergebnis-neutral; Werte von vor #78 (8 Felder) sind nicht vergleichbar.

Mehrere Messblöcke (`--repeat`): die VM streut zwischen Prozessläufen spürbar (CPU-Takt, Nachbarlast), innerhalb eines Laufs weniger. Kennzahl ist das MINIMUM, der Block mit der wenigsten Fremdstörung. Die Pass-Tabelle stammt dagegen aus dem letzten Block; beide werden getrennt ausgewiesen.

Betrifft: `SimCore/Sources/SimPerf/main.swift`, `SimConfig.production`, `SimConfig.productionSettleYears`, `Terrain.fingerprint`, `SimProfile`
