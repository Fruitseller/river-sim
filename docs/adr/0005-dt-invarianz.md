# Framerate-Unabhängigkeit: Relaxation, Schritt-Deckel, Tropfen-Strom

Echtzeit-Zeitraffer (winziges dt je Frame) und +10.000-Jahre-Sprünge müssen dasselbe Ergebnis liefern (Issue #2).

Relaxation: `Terrain.relaxFraction(dt:tau:)` = `1 − e^(−dt/τ)` ist die einzige Quelle aller Relaxations- und Verlandungsraten. Der Rest teleskopiert exakt, `(1 − f(dt₁))·(1 − f(dt₂)) = 1 − f(dt₁ + dt₂)`. Bewusst ohne Prüfung von `tau`: die Aufrufer bewachen ihre Zeitkonstante selbst, ein Deckel hier verschöbe ihr Randverhalten.

Schritt-Deckel: Pässe, die ihren Eingriff auf einen Anteil der lokalen Höhendifferenz deckeln, nahmen fest 0,5 je Schritt; viele kleine Schritte kommen der Grenze beliebig nahe, ein großer bleibt bei der Hälfte stehen. Bei kleinem dt ist der feste Deckel richtig (er greift kaum, das Gelände nähert sich asymptotisch), der Fehler sitzt nur bei großem dt. Deshalb `stepCapFraction(dt) = max(0,5, 1 − e^(−dt·ln2/500))`: bis 500 J. exakt die alten 0,5, damit bleibt die Kalibrierung aller Wächter mit dt ≤ 500 bit-genau; darüber 0,75 bei 1000, 0,94 bei 2000 (vier 500-Jahr-Schritte: 0,9375). Der Deckel gibt nie mehr frei als die volle Höhendifferenz. Bewusst nicht über `relaxFraction(dt:, tau: 500/ln2)`: in Reellen dasselbe, aber nicht bitgleich, und die Zahl ist als Halbwertszeit auf 0,5 bei dt = 500 kalibriert.

Tropfenzahl: sie ist eine Rate (`hydraulicPerYear` · Fläche · dt). Unter einem halben Jahr je Schritt ist der Sollwert < 1; der angebrochene Tropfen wird in `dropCarry` mitgenommen, über die Zeit ist die Zahl exakt ∝ Simulationszeit.

Tropfen-Strom: jeder Tropfen zieht seinen Startpunkt aus einem eigenen, aus seiner laufenden Nummer `dropsEmitted` abgeleiteten Strom (`Hydraulic.dropRNG`). Tropfen Nr. j ist damit derselbe, ob er einzeln in einem Frame-Schritt fällt oder als einer von 360 in einem Sprung. Vorher lief der Strom über einen Schrittzähler: die Zahl war dt-invariant, die Tropfen nicht. Die Einmal-Charge aus einem Strom ab `seed` bleibt für Chargen ohne Zeitbezug (Stream-Map-Spin-up der Generierung), die so ihre kalibrierte Realisierung behalten. Mulberry32 liefert aus benachbarten Startzuständen keine unabhängigen ersten Ausgaben; der Index wird deshalb mit dem splitmix64-Finalizer gemischt, dazu ein Aufwärm-Zug.

Startpunkte: abflussgewichtet über `flowWeight` per Ablehnungs-Stichprobe (Vorschlag gleichverteilt, angenommen mit `weight/weightMax`), statt je Charge eine 700k-Zellen-Verteilungstabelle zu bauen. Höchstens 24 Neuziehungen je Tropfen; die Annahmerate liegt gemessen bei 0,34 … 0,54 (max(w) 1,84 … 2,91, n = 832, Seeds 1337/7/99), Rest-Verzerrung im ungünstigsten Fall 0,66^24 ≈ 2·10⁻⁵. Zellen mit Maximalgewicht werden ohne Ziehung angenommen, ein konstantes Gewichtsfeld ist so bit-identisch zum ungewichteten Fall.

Stream-Map: gemittelt wird die lineare Besuchsrate (Besuche/Jahr), gesättigt erst danach, rational `rate/(rate + r0)` statt `1 − exp(−rate/r0)` (gleiche Form, ohne 409k `exp`-Aufrufe je Schritt).

Verworfen:
- Linear gedeckelte Relaxation `min(1, dt/τ)`: teleskopiert nicht und sättigt bei großen Schritten.
- `max(1, …)` für die Tropfenzahl: dauerhaft aufgerundete Erosion bei Frame-Schritten.
- Schritt-Deckel als reine Exponentialform ohne Untergrenze: drosselt kleine Schritte künstlich (dt = 20 J.: 0,027 statt 0,5) und verschob die Wächter in 20-Jahr-Schritten (`testBasinLevelIsRateLimited`: Spiegelsprung 0,0073 gegen die Schranke 0,002; mit Anker 100 J. `testEndorheicMechanicsSurviveLithology`).
- Tropfen-Index nur mit `index · 2654435761` gemischt: die gewichtete Luv/Lee-Drainagedichte fiel von ×1,14 auf ×1,01, obwohl Randverteilung und Serienkorrelation unauffällig waren; der Fehler steckte in der Kopplung von Position und Annahme-Zug. Mit Finalizer und Aufwärm-Zug ×1,21.
- Sättigung der Stream-Map vor der Mittelung: dt-abhängig, ein Einzelbesuch saturierte bei kleinen Schritten sofort, Zufallspfade so hell wie Flüsse.

Folgen: Der Scour-Deckel in `braidPass` bleibt bewusst bei festen 0,5 je Schritt (AGENTS.md, `docs/dt-invariance-measurements.md` §6). `dropsEmitted` und `dropCarry` gehören zum Spielstand.

Betrifft: `Terrain.relaxFraction`, `Terrain.stepCapFraction`, `Terrain.dropCarry`, `Terrain.dropsEmitted`, `Terrain.spinUpStreamMap`, `Terrain.streamMap`, `Terrain.streamRate`, `Terrain.deriveStreamMap`, `Hydraulic.erode`, `Hydraulic.dropRNG`, `Hydraulic.spawnPosition`, `Hydraulic.spawnRejectionTries`, `docs/dt-invariance-measurements.md`
