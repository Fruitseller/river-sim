# Gletscher: sub-getakteter Eistransport, exakte Bilanz, Lawinen des Firns

`updateIce` (#35) zieht das Eisfeld je Schritt nach. Logbuch: `SimConfig.iceEnabled` ff., Modellwahl `docs/research-climate-cryosphere.md` §4/§5, Messreihen `docs/glacier-measurements.md`.

    s      = h + ice                                  Eis-Oberfläche (h ist das Bett)
    out(k) = min(kappa·I·ΣΔs⁺, moveFrac·I)            Ausstrom je Teilschritt
    I      ← I + Σ_nb out(nb)·Δs⁺(nb→k)/ΣΔs⁺(nb) − out(k)
    E      = iceErodeK · (I·S)^m · S,  S = ΣΔs⁺/cellSize    (Flux-Modell, n = 1)
    a      = iceFirnPerSnowYear · snow · clamp(−T/coldSpan, 0, 1)
    μ      = 1/iceTurnoverYears + iceMeltPerKYear · max(0, T)
    I      ← I* + (I − I*)·e^(−μ·dt),  I* = a/μ
    Moräne = iceMoraineK · (Schmelz-Anteil von ∫μ·I dt)

Sub-Taktung wie bei der Hangdiffusion: die Transportzahl des ganzen Schritts (`kappa_Jahr · dt`) wird auf gleich starke Teilschritte verteilt, die unter beiden Stabilitätsgrenzen bleiben. Damit ist die Wirkung ∝ dt; ein +10.000-Jahre-Sprung transportiert so viel wie 50.000 Schritte à 0,2 Jahre (`Glacier.testIceIsFramerateIndependent`). kappa ist auflösungsunabhängig (∝ (n−1)², auf n = 640 kalibriert), dieselbe Umrechnung wie bei der Hangdiffusion.

Die zwei Grenzen je Teilschritt: `kappa · ΣΔs⁺ ≤ iceFlowSubCap` (Anteil der Säule, der die Zelle verlässt; Positivität, am steilsten Eishang) und `kappa · I ≤ iceFlowSubCap / 2` (Diffusionszahl der Eisoberfläche an der dicksten Säule). Der Schachbrettmodus des 5-Punkt-Sterns wächst je Teilschritt um `1 − 8·kappa·I`: über 1/4 schaukelt er sich auf, zwischen 1/8 und 1/4 kippt er das Vorzeichen, erst unter 1/8 ist das Ergebnis konvergiert (gemessen: Grenze 1/4 gegen 1/8 −6 … −12 % Eismasse, 1/8 gegen 1/16 < 0,01 %). Bis #174 galt nur die erste Grenze; dickes Eis auf flachem Bett lief bei dt = 1000 instabil (Rauheit ×70, Schliff 0,065 in einem Schritt gegen 0,005 bei zehn Schritten à 100, `docs/glacier-measurements.md` §L). Beide Maxima werden einmal je Schritt gemessen (`iceTransportDomain`, `max(ΣΔs⁺_max, 2·I_max)`), statt `ΣΔs⁺ ≤ 1` anzunehmen; die Annahme machte die Sub-Taktung um 1/wMax (gemessen 5…20) zu fein, und der Pass dominierte den Schritt (§E). Der harte Deckel `iceFlowMoveFraction` bleibt, weil ein Sculpt-Eingriff die Oberfläche zwischen Messung und Teilschritten versteilern kann.

Determinismus: jeder Teilschritt hat zwei zeilenparallele Pässe. Pass 1 liest `h`/`ice` und schreibt Ausstrom je Einheit Abfall (`iceRate`) und die eingefrorene Oberfläche (`iceSurf`); der Deckel `moveFrac·I` sitzt hier, negatives Eis ist ausgeschlossen. Pass 2 liest nur diese Puffer der Nachbarschaft und schreibt nur den eigenen Index; ohne die eingefrorene Oberfläche läse der Nachbar ein halb erodiertes Gefälle und das Ergebnis hinge an der Thread-Aufteilung. `ΣΔs⁺` wird in Pass 2 in derselben Nachbar-Reihenfolge (l, r, d, u) gebildet wie in Pass 1, damit Ausstrom und gutgeschriebener Zufluss dieselbe Zahl sind (bis auf die eine Division, gegen die `if I < 0` steht).

Arbeitsfenster: im Teilschritt s liegt Eis nur innerhalb von s Zellen um die Anfangssäulen und Firnquellen, also rechnet Pass 2 je Zeile `s + 1` Zellen darum, wachsend statt von Anfang an um nSub (bei Seed 1337 deckt das Eis rund ein Zehntel des Rechtecks). Zellen außerhalb tragen weder Eis noch Zufuhr noch Zufluss; bit-identisch zum vollen Rechteck. Pass 1 friert zusätzlich einen Rand (`halo`) ein.

Schnell-Ausstiege, alle bit-identisch: ohne Eis und ohne Zufuhr tut der Pass nichts und leert die Maske (Abnahmekriterium des Tickets: Stand vor #35). In Pass 2 überspringt eine eisfreie Zelle ohne Schnee, Lawinenzufuhr und ausströmende Nachbarn die verzweigten Zuflusssummen (spart ~50 % fehlvorhergesagte Zweige auf dem Höhenrauschen), und eine Zelle ohne Eis, Zufluss und Zufuhr wird nicht gerechnet (`0 + (0−0)·e^… = 0`).

Temperatur: der Teilschritt rechnet sie aus dem Bett, das er gerade vor sich hat (dieselbe Formel wie `updateClimate`), statt das Feld vom Schrittende davor zu lesen. Der Schliff senkt das Bett, und das Eis sähe sonst das kältere, höhere Bett (gemessen 3 % mehr Eis je 1000-Jahr-Schritt als in zehn à 100, §L). `snow` dagegen bleibt auf dem Stand des vorigen Schrittendes.

Moräne: `∫₀^dt μ·I dt = μ·I*·dt + (I₀−I*)·(1−e^(−μdt))`, davon zählt nur der Schmelzanteil von μ; der Grundumsatz ist Sublimation/Kalben und trägt keinen Schutt. Im Nährgebiet (T ≤ 0) ist der Anteil exakt 0. Was das Meer erreicht, kalbt und geht verloren; ein Schelfeis-Modell wäre eigene Physik, die Insel ist dafür zu klein.

Lawinen (`SimConfig.iceAvalancheSlopeHi`): einmal je Schritt aus dem Bett vom Schrittanfang bekommt jede kalte, beschneite Zelle mit Makrosteigung über `Lo` (Maximum im Umkreis `iceAvalancheReach`) ein Ziel, die erste nicht steile Zelle am Hangfuß auf dem steilsten Abstieg (8 Nachbarn, Diagonale √2), und einen Anteil `φ = smoothstep((s − Lo)/(Hi − Lo))`. Der Lauf endet vor dem Meer und in Mulden. Weltsteigung wird mit `cellSize / (2 · heightScale)` auf Makrosteigung umgerechnet; `macroSlope` mittelt beide Achsen, der Faktor 2 macht eine achsenparallele Wand exakt. Die Karte ist dt-neutral (Eis allein auf festem Bett: dt 15,6 / 100 / 1000 gleich auf 0,01 %); eine Karte je 15 Sim-Jahre oder je Teilschritt ändert die dt-Spanne der Langläufe nicht, kostet aber ein Vielfaches (§M). Die Abgabe `φ · a` rechnet `applyAvalancheFeed` mit derselben Firnformel wie Pass 2, damit eine Quelle mit φ = 1 exakt 0 behält; seriell über die aufsteigend sortierte Liste, also feste Summationsreihenfolge.

Betrifft: `Terrain.updateIce`, `Terrain.iceFlowSubStep`, `Terrain.iceTransportDomain`, `Terrain.IceDomain`, `Terrain.iceAvalancheMap`, `Terrain.applyAvalancheFeed`, `SimConfig.iceFlowSubCap`, `SimConfig.iceFlowMoveFraction`, `SimConfig.iceAvalancheSlopeHi`
