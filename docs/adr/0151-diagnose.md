# Gelände-Diagnose ohne eigene Regelformeln

`TerrainDiagnostics` (aus `SimNode` ausgelagert, Issue #53) liefert den Kennzahlen-Vertrag für die Anzeige und die Δ-Karte gegen einen Vergleichspunkt. Der Vergleichspunkt ist der einzige Zustand; er zeigt, ob Relief durch Abtragung nur freigelegt oder durch Hebung oder Ablagerung aufgebaut wird. Die Regelformeln (Relief-Signal, Servo, Gratkrümmung) kommen aus SimCore selbst; dupliziert die Anzeige sie, zeigt sie etwas anderes als wirkt.

Die Kennzahlen reisen als Float32-Array, damit kein Dictionary-Marshalling im Renderpfad anfällt. Reihenfolge: min, mean, max, Landrelief, deltaMean, deltaMax, Volumen unter/über Referenz, Nettovolumen, maxAbtrag, maxAufbau, Relief-Servo/100 J., abklingende Hebung U(t)/100 J., Reliefziel, Referenzjahr, ungültige Zellen, robustes Relief-Signal (Regelsignal des Servo-Bodens, p95 − Median), mittlere Gratkrümmung (negativ = spitz, → 0 = rund), Talseitenrelief (Median − p05). Die Indizes stehen als `DBG_*` in `Main.gd`, ihre Zahl als `DEBUG_STATS_COUNT`; Wächter: `SimCoreTests/DiagStatsContractTests.swift`.

Regelsignal, Talseiten-Gegenprobe und Servo hängen am selben Quantil-Tripel der Landhöhen (p05, Median, p95). Deshalb ein Histogramm-Pass über `Terrain.landHeightQuantiles` statt drei; `landReliefRobust()`, `landReliefLow()` und `reliefServoRate()` zählten je einen eigenen, gemessen rund 1,4 ms je Pass bei n = 832. Die angezeigten Werte sind unverändert.

Talseiten-Gegenprobe (Issue #26): das Regelsignal ist die Hochseite (p95 − Median). Nach großflächiger Einebnung bleibt sie lange bei rund 0, während sich die Fläche nach unten differenziert; ohne die zweite Hälfte liest die Diagnose das als „keine Erholung".

Betrifft: `TerrainDiagnostics`, `TerrainDiagnostics.stats`, `Terrain.landHeightQuantiles`, `game/scripts/Main.gd` (`DBG_*`)
