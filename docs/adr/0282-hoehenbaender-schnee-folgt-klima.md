# Höhenbänder: Vegetation und Fels folgen Perzentilen, der Schnee dem Klima

Seit #4 sind Hochfels-, Nadel- und Vegetationsgrenze an Perzentile der aktuellen Landhöhenverteilung gekoppelt, damit sie nicht als absolute Werte aus dem erreichbaren Höhenband herausaltern (`docs/height-band-measurements.md`). Seit #33 ist der Schnee kein Perzentil mehr: seine Grenze wird aus dem Schneefeld (Massenbilanz aus Temperatur und Niederschlag) zurückgerechnet (`docs/climate-snow-measurements.md`). Eine Temperatur ist eine Höhe, keine Fläche; die Wächter prüfen deshalb, dass die Schneegrenze dem Klima folgt und nicht der Höhenverteilung.

Bis #33 lautete die Zusicherung „Schneezone nie leer, enges Flächenband" (Rampe/voll 0.0151/0.0015 bei Jahr 0, 0.0149/0.0015 nach 30k, per Konstruktion konstant, weil `bandSnowPercentile` einen Flächenanteil festschrieb). Jetzt gilt umgekehrt: `snowStart` bleibt über den Lauf praktisch konstant, der Flächenanteil schrumpft, während die Insel abgetragen wird. Gemessen (n = 832 mit `calibrationWorld`, die alte Produktionspaarung; Seed 1337, Rampe = Landanteil mit Schnee > 0, §3):

| Jahr | Rampe | snowStart | maxH | T(Gipfel) |
|---|---|---|---|---|
| 0 | 0.0139 | 0.5721 | 0.7457 | −4.49 °C |
| 10k | 0.0115 | 0.5716 | 0.6726 | −2.59 °C |
| 30k | 0.0090 | 0.5716 | 0.6359 | −1.63 °C |

Die 0-°C-Isotherme liegt rechnerisch bei `sea + T₀/Γ` = 0.5730, genau bei `snowStart`. Schranken: `snowStart` wandert über 30k höchstens 0.005 (Rest ist Histogramm-Quantisierung 0.000488 plus Luv/Lee-Streuung; vor #33 fiel `snowStart` im selben Lauf um über 0.01). Die Fläche muss unter 0.90 des Startwerts fallen (vorher 0.85; gemessen 0.864, 0.0610 → 0.0527): seit der Entkopplung der Eis-Firn-Grenze (#174, `iceFirnTemp`) schleift das Eis den Gipfel nicht mehr so früh unter die Isotherme. Ein fester Landanteil wäre 1.0. Der Test läuft ohne Lawinen-Abgang (`pinIceBeforeAvalanche`): mit ihm bleiben die Gipfel stehen (Maximum nach 30k 0.726 statt unter 0.70), und Vorbedingung „Insel trägt ab" und Schranke sind am Stand davor gemessen.

Perzentil-Bänder ziehen mit, wenn das Terrain sinkt (n = 160, Seed 1337, 60k Jahre, Stand #33): vegFull 0.4945 → 0.4378, maxH 0.6864 → 0.5762. Die Trajektorie im Dokument stammt aus der #4-Zeit (0.4383 / 0.5807); die Differenz ist Physik-Entwicklung seit #11/#12/#13, nicht das Klima (das koppelt in keinen Pass, Wächter `ClimateSnow.testDisabledClimateIsBitIdenticalPhysics`). Der Schnee ist im selben Test die Gegenprobe: vor #33 wanderte `snowStart` von 0.5658 auf 0.5072 mit, jetzt 0.5702 → 0.5687. Entweder die Grenze steht, oder die Zone ist leer und das Band liegt über dem Land; beides schließt Mitwandern nach unten aus.

Schneefreies Klima ist ein gültiger Zustand (warme Welt oder flach erodierte Insel): das Band muss dann vollständig über dem Land liegen, sonst wären die Gipfel weiß, obwohl das Klima keinen Schnee trägt.

Die Perzentile kommen aus derselben Quantil-Funktion wie das Relief-Signal (`Terrain.landHeightQuantiles`), die exakt das liefert, was `landReliefRobust` vorher selbst rechnete.

Betrifft: `HeightBandTests`, `HeightBands.fromLandHeights`, `Terrain.landHeightQuantiles`, `Terrain.updateHeightBands`
