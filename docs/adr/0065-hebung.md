# Abklingende Hebung exakt integriert, Relief-Servo nur als Untergrenze

Die Tektonik hebt nach `U(t) = U_floor + (U₀ − U_floor)·e^(−t/τ)` ab (post-orogener Zerfall, `docs/research-terrain-aging.md` §3). Der Relief-Servo ist nur noch Untergrenze: er greift, wenn U(t) das Relief nicht mehr über `reliefTarget` hält, im normalen 100k-Fenster gemessen nie.

## Exakte Integration

`step()` sampelt die Rate nicht am Schrittanfang, sondern integriert sie über das absolute Zeitintervall `[a, b]`:

    ∫ U(t) dt / 100 = [U_floor·(b−a) + (U₀ − U_floor)·τ·(e^(−a/τ) − e^(−b/τ))] / 100

Die geschlossene Form ist die Framerate-Unabhängigkeit des Passes: die Summe über viele Mini-Schritte teleskopiert exakt zum Wert eines Sprungs. `upliftDecayRatePer100y` ist reine Anzeige.

Mit Servo ist die Hebung eines Schritts `∫ max(U(t), U_servo) dt / 100`. Das punktweise `max` unter dem Integral ist der Punkt: `max(∫U, U_servo·dt)` wäre schrittweitenabhängig, weil bei kleinen Schritten im hinteren Teil schon der Servo übernähme, wo im großen Schritt noch das Integral von U gewinnt. Der Schritt wird deshalb am Schnittpunkt geteilt, `t* = −τ · ln((U_servo − U_floor) / (U₀ − U_floor))`; `t*` hängt nur von der Config ab, die Zerlegung ist über beliebige Unterteilungen additiv. Die Servo-Rate selbst wird wie bei jedem Regler einmal je Schritt aus dem aktuellen Relief gelesen; im Produktionsbetrieb ist sie über das ganze Alterungsfenster 0. Wächter: `TerrainAging.testServoFloorCrossingIsFramerateIndependent`.

## Wirkung im Feld

`gatedAmount` ist die über den Schritt integrierte Hebung (Höheneinheiten bei `upliftBase == 1`). Sie wirkt NUR über den positiven Teil des Tektonik-Felds und NUR auf Land, sie soll Grate tragen. Mit vollem `upliftBase` (Täler negativ) senkte sie die Täler unter den Meeresspiegel (halbe Insel geflutet); ohne Land-Gate hob sie den Schelf in Tektonik-Ringen über die Wasserlinie (grüne Kratersäume vor der Küste, beides gemessen).

`cfg.upliftPer100y` ist die Alt-Konstante der Dauer-Hebung (Produktion 0, nur von Testkonfigs wie `meanderCfg()` gesetzt, die alte Werte pinnen) und wirkt weiter über das volle Feld.

## Servo-Rate: eine Formel

`reliefServoRate()` ist die einzige Quelle für `step()` und die Diagnose-Anzeige; beide hatten die Formel früher dupliziert und konnten auseinanderlaufen. Die Variante `reliefServoRate(reliefSignal:)` nimmt ein schon gemessenes Regelsignal: der Histogramm-Pass kostet bei n = 832 gemessen ~1.4 ms (s. `updateHeightBands`), und die Anzeige zeigt Regelsignal, Talseite und Servo gemeinsam; ohne diesen Einstieg zählte sie dieselbe Höhenverteilung dreimal.

Betrifft: `Terrain.applyUplift`, `Terrain.upliftAmount`, `Terrain.upliftDecayIntegral`, `Terrain.upliftDecayRatePer100y`, `Terrain.reliefServoRate`, `SimConfig.upliftPer100y`, `SimConfig.reliefTarget`, `docs/research-terrain-aging.md`
