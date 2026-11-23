# Klima-Vertikale und Höhenzonen: Schneebilanz aus der Temperatur, Zonen als Quantile

Bis #4 hingen Vegetations-, Fels- und Schneezone an absoluten Höhen, bis #33 war Schnee reine Farbe (die obersten 1,5 % weiß). Absolute Schwellen altern mit jeder Neukalibrierung aus dem erreichbaren Höhenband heraus: gemessen (n = 832, Seed 1337) lag die alte Schnee-Schwelle 1,05 immer über dem höchsten Punkt (maxH 0,7457 bei Jahr 0, 0,6372 nach 30k), die Graurampe ab 0,58 traf 1,1 % → 0,6 % des Landes.

Höhenzonen als Quantile (#4): Grenzen für Vegetation und Hochfels kommen aus Quantilen der aktuellen Landhöhen. Ein Perzentil definiert die Zone als Flächenanteil und zieht mit der abklingenden Hebung mit, ohne dass jemand die Farben nachzieht. Die obere Vegetationsgrenze ist kein zweites Perzentil, sondern eine Breite aus der robusten Relief-Spanne (p95 − p50): die alte Grenze 0,68 lag bei p99,99 und hinge an den obersten paar Zellen; der Entwurf mit p99,9 machte die Rampe schmaler und kippte zwei #12-Wächter. Sim (`updateVegetation`) und Biom-Färbung lesen dieselben Bänder; bis #4 hielten sie zwei Kopien mit auseinanderlaufenden Konstanten (Höhenabfall ab 0,5 bzw. 0,6, Regenfaktor 1,3 bzw. 1,2). `HeightBands.legacyAbsolute` bleibt als Rückfall ohne auswertbare Landverteilung und als Pin für Wächter an einem konkreten Becken.

Klima (#33): zwei Felder, `Terrain.temperature` und `Terrain.snow`, und eine Massenbilanz:

    T(k)   = climateSeaLevelTemp − climateLapseRate · max(0, h[k] − sea)
    a(k)   = snowAccumPerYear · rain[k] · f_schnee(T)
    μ(k)   = 1/snowTurnoverYears + snowMeltPerKYear · max(0, T)
    dS/dt  = a − μ·S   ⇒   S ← S* + (S − S*)·e^(−μ·dt),  S* = a/μ

Die Relaxationsform teleskopiert exakt und braucht kein Clamping. Eine feste Schmelzmenge `S ← max(0, S + (a − m)·dt)` ist verworfen: das `max` verwirft in einem großen Schritt Schmelzguthaben, das kleine Schritte gegen frischen Schnee verrechnet hätten. Das Klima koppelt nicht direkt in Erosion oder Vegetation (Kalibrier-Kaskade über `vegDamp`), sondern nur über Schmelzabfluss (#36) und Eis (#35). Aus (`climateEnabled = false`) ist bit-identisch zum Stand vor #33.

Vertikaler Maßstab: `h` ist normiert, `world`/`cellSize` koppeln nur horizontal. Deshalb Γ = 6,5 K/km (ICAO) × H_ref mit H_ref = 4000 m je Höheneinheit, also 26 K; der höchste Punkt der frischen Insel liegt bei ≈ 2380 m, alpines Mittelgebirge. ISA statt trocken- (9,8) oder feuchtadiabatisch (3,6–9,2 K/km) als Kompromiss für eine feuchte maritime Insel. T₀ = 11 °C legt die 0-°C-Isotherme bei der Generierung dorthin, wo der Perzentil-Schnee begann (0,573 gegen p98,5 = 0,5699).

Schneegrenze aus dem Schneefeld: `snowStart`/`snowFull` kommen aus dem gemessenen beschneiten Landanteil (`Terrain.snowAreaFractions()`), zurückgerechnet in ein Höhenquantil. Die Zone folgt so dem Klima: flacht die Insel unter die Isotherme ab, verschwindet sie, statt als fester Flächenanteil auf die höchsten Grate zu wandern (vorher sank `snowStart` bei n = 160 über 60k von 0,5658 auf 0,5072). Die Schnee-Perzentile bleiben nur der Rückfall bei abgeschaltetem Klima.

Verworfen:
- H_ref 2000 m (Γ = 13, Gipfel 1190 m): bei jedem T₀ > 5 °C, das die Küste eisfrei hält, läge die 0-°C-Grenze über dem Gipfel, nie Schnee.
- H_ref 8000 m (Γ = 52, Gipfel 4766 m): das obere Drittel dauerhaft unter Frost, die alternde Insel bewegte die Schneezone kaum.
- Absolute Höhenschwellen und eine obere Vegetationsgrenze als Perzentil: s. o.

Werte je Konstante: `docs/climate-snow-measurements.md` und `docs/height-band-measurements.md`, je § Kalibrierwerte; Herleitung und Quellen `docs/research-climate-cryosphere.md`.

Betrifft: `HeightBands`, `HeightBands.fromLandHeights`, `HeightBands.legacyAbsolute`, `HeightBands.vegRamp`, `Terrain.heightBands`, `Terrain.landHeightQuantiles`, `Terrain.snowAreaFractions`, `Terrain.vegetationSuitability`, `Terrain.updateClimate`, `SimConfig.climateEnabled`, `SimConfig.climateSeaLevelTemp`, `SimConfig.climateLapseRate`, `SimConfig.snowMeltPerKYear`, `SimConfig.bandVegRampSpanFactor`, `SimConfig.heightBandsOverride`
