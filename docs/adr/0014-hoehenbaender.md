# Höhenbänder als Quantile der Landhöhen, Schnee aus dem Schneefeld

Grenzen für Vegetation, Hochfels und Schnee kommen aus Quantilen der aktuellen Landhöhen statt aus absoluten Höhenwerten (Issue #4). Absolute Schwellen altern mit jeder Neukalibrierung aus dem erreichbaren Höhenband heraus; ein Perzentil definiert die Zone als Flächenanteil und zieht mit der abklingenden Hebung (#13) mit, ohne dass jemand die Farben nachzieht.

Gemessen (n=832, Seed 1337, Produktions-Defaults, `docs/height-band-measurements.md`): die Landhöhen enden bei maxH 0,7457 (Jahr 0) bzw. 0,6372 (30k Jahre). Die alte Schnee-Schwelle 1,05 lag IMMER über dem höchsten Punkt (0 Zellen), die Graurampe ab 0,58 traf 1,1 % → 0,6 % des Landes. Der Anteil über einer Perzentil-Grenze ist per Konstruktion fest; flacht das Terrain ab, wird die Zone nicht großflächig, sie wandert auf die höchsten Grate.

## Schnee seit #33

`snowStart`/`snowFull` kommen nicht aus einem konfigurierten Perzentil, sondern aus den gemessenen Landanteilen, die das Klima beschneit (`Terrain.snowAreaFractions()`): Slots 4/5 sind das Komplement (1,5 % beschneites Land → Quantil p98,5). Das Band schneidet so viel Fläche ab, wie das Schneefeld belegt, und folgt dem Klima; flacht die Insel unter die 0-°C-Isotherme ab, verschwindet die Schneezone, statt auf die höchsten Grate zu wandern. `bandSnowPercentile`/`bandSnowFullPercentile` sind der Rückfall für `climateEnabled = false`, bit-identisch zu vor #33. Wächter: `HeightBandTests.testSnowZoneFollowsTheClimateNotAFixedLandFraction`.

Ein schneefreies Klima ist gültig (warme Welt, flach erodierte Insel). Bei Anteil 0 liefert das Quantil p = 1 die Mitte des höchsten besetzten Histogramm-Bins (Breite 0,000488, `Terrain.landHeightQuantiles`); `snowStart` liegt deshalb 2·`bandMinRampWidth` (0,008) darüber, damit `snowAmount` auf ganz Land exakt 0 ist.

## Vegetations-Rampe als Breite

`vegRamp` ist eine Quantil-SPANNE: `bandVegRampSpanFactor · (p95 − p50)`, dasselbe Quantilpaar wie `Terrain.landReliefRobust`. Die obere Vegetationsgrenze lag früher bei 0,68 und damit über dem 99,99-Perzentil; ein Perzentil für diese Breite hinge an den obersten paar Zellen, die robuste Relief-Spanne kommt aus zehntausenden. Gespeichert wird die BREITE, nicht die obere Grenze: `vegetationAltitudeFactor` teilt durch sie, und eine als Differenz gerechnete Breite ist in Double nicht dasselbe wie der Literalwert (`0.68 − 0.5 == 0.18000000000000005`). Diese eine ulp kippte `EndorheicEvaporation`-Wächter (Beckenrollen wechseln diskret); mit der Breite als Wert reproduziert `legacyAbsolute` die Vor-#4-Arithmetik exakt.

## Robustheit und Rückfall

Die Config darf die Perzentile in jeder Reihenfolge setzen: `landHeightQuantiles` will sie aufsteigend (ein Histogramm-Durchlauf), deshalb wird sortiert und zurückverteilt, statt still auf `legacyAbsolute` zu kippen. Jede Rampe bekommt mindestens `cfg.bandMinRampWidth` (eine spiegelglatte Insel hätte sonst identische Quantile, also eine Sprungfunktion).

`legacyAbsolute` hält die absoluten Schwellen von vor #4 in zwei Rollen: Rückfall ohne auswertbare Landverteilung (< 20 Landzellen: frisch geflutete Welt, synthetische Testfelder) und Pin für Wächter, die an EINEM konkreten Becken/Lauf hängen (`SimConfig.heightBandsOverride`); dort muss die Vegetation exakt wie vor #4 rechnen, deshalb Literale und die Rampenbreite als Wert 0,18.

## Eine Quelle für Sim und Färbung

`updateVegetation` (SimCore) und die Biom-Färbung (`SimRender.TerrainColorRenderer`, bis #80 in der Brücke) hielten bis #4 zwei Kopien derselben Höhen-/Hang-/Feuchte-Logik mit auseinanderlaufenden Konstanten (Höhenabfall ab 0,5 bzw. 0,6, Regenfaktor 1,3 bzw. 1,2). Beide lesen jetzt `Terrain.heightBands` und `Terrain.vegetationSuitability`. Die Bänder sind `Codable` und reisen im Spielstand mit (#8), damit die Färbung nach dem Laden sofort stimmt.

Betrifft: `HeightBands`, `HeightBands.fromLandHeights`, `HeightBands.legacyAbsolute`, `HeightBands.vegRamp`, `Terrain.landHeightQuantiles`, `Terrain.snowAreaFractions`, `SimConfig.bandVegRampSpanFactor`, `SimConfig.heightBandsOverride`
