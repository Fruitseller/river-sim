# Framerate-Unabhängigkeit: Relaxation, Schritt-Deckel, Tropfen-Strom

Echtzeit-Zeitraffer (winziges dt je Frame) und +10.000-Jahre-Sprünge müssen dasselbe Ergebnis liefern (Issue #2).

Relaxation: `Terrain.relaxFraction(dt:tau:)` = `1 − e^(−dt/τ)` ist die einzige Quelle aller Relaxations- und Verlandungsraten. Der Rest teleskopiert exakt, `(1 − f(dt₁))·(1 − f(dt₂)) = 1 − f(dt₁ + dt₂)`. Bewusst ohne Prüfung von `tau`: die Aufrufer bewachen ihre Zeitkonstante selbst, ein Deckel hier verschöbe ihr Randverhalten.

Schritt-Deckel: Pässe, die ihren Eingriff auf einen Anteil der lokalen Höhendifferenz deckeln, nahmen fest 0,5 je Schritt; viele kleine Schritte kommen der Grenze beliebig nahe, ein großer bleibt bei der Hälfte stehen. Bei kleinem dt ist der feste Deckel richtig, der Fehler sitzt nur bei großem dt. Deshalb `stepCapFraction(dt) = max(0,5, 1 − e^(−dt·ln2/500))`: bis 500 J. exakt die alten 0,5, damit bleibt die Kalibrierung aller Wächter mit dt ≤ 500 bit-genau; darüber 0,75 bei 1000, 0,94 bei 2000. Bewusst nicht über `relaxFraction(dt:, tau: 500/ln2)`: in Reellen dasselbe, aber nicht bitgleich, und die Zahl ist als Halbwertszeit kalibriert.

Braid-Deckel: die Deposition in `braidPass` ist eine geometrische Obergrenze `hf + braidDeltaCeiling` statt einer Zugabe je Schritt. Vorher setzte `max(0, hf − h) + 0,005` nach Erreichen des Spiegels jeden Schritt nochmal 0,005 drauf, der Uferaufbau wuchs mit der Schrittzahl statt mit der Zeit. Der Scour-Deckel bleibt dagegen bewusst bei festen 0,5 der lokalen Differenz je Schritt, nicht `stepCapFraction`: als Rate dürfte ein 200-Jahr-Schritt 0,75 ausräumen, der Braid-Scour grub dann die Böden abflussloser Becken tiefer, die verkrustete Playa-Fläche fiel von > 100 auf 35 Zellen, und `testDriedBedIsRenderedAsPlaya` sowie `testBasinLevelIsRateLimited` kippten (`docs/dt-invariance-measurements.md` §6). Das ist eine benannte, bekannte Schrittweitenabhängigkeit (#275).

Tropfenzahl: sie ist eine Rate (`hydraulicPerYear` · Fläche · dt). Der angebrochene Tropfen wird in `dropCarry` mitgenommen, über die Zeit ist die Zahl exakt ∝ Simulationszeit.

Tropfen-Strom: jeder Tropfen zieht seinen Startpunkt aus einem eigenen, aus seiner laufenden Nummer `dropsEmitted` abgeleiteten Strom (`Hydraulic.dropRNG`). Tropfen Nr. j ist damit derselbe, ob er einzeln in einem Frame-Schritt fällt oder als einer von 360 in einem Sprung. Vorher lief der Strom über einen Schrittzähler: die Zahl war dt-invariant, die Tropfen nicht. Mulberry32 liefert aus benachbarten Startzuständen keine unabhängigen ersten Ausgaben; der Index wird deshalb mit dem splitmix64-Finalizer gemischt, dazu ein Aufwärm-Zug. Die Einmal-Charge aus einem Strom ab `seed` bleibt für Chargen ohne Zeitbezug (Stream-Map-Spin-up der Generierung).

Startpunkte: abflussgewichtet über `flowWeight` per Ablehnungs-Stichprobe statt je Charge eine 700k-Zellen-Verteilungstabelle. Höchstens 24 Neuziehungen je Tropfen; Annahmerate gemessen 0,34 … 0,54, Rest-Verzerrung im ungünstigsten Fall 0,66^24 ≈ 2·10⁻⁵. Ein konstantes Gewichtsfeld ist bit-identisch zum ungewichteten Fall.

Stream-Map: gemittelt wird die lineare Besuchsrate (Besuche/Jahr), gesättigt erst danach, rational `rate/(rate + r0)` statt `1 − exp(−rate/r0)` (gleiche Form, ohne 409k `exp`-Aufrufe je Schritt).

Verworfen:
- Linear gedeckelte Relaxation `min(1, dt/τ)`: teleskopiert nicht und sättigt bei großen Schritten.
- `max(1, …)` für die Tropfenzahl: dauerhaft aufgerundete Erosion bei Frame-Schritten.
- Schritt-Deckel als reine Exponentialform ohne Untergrenze: drosselt kleine Schritte künstlich (dt = 20 J.: 0,027 statt 0,5) und verschob die Wächter in 20-Jahr-Schritten (`testBasinLevelIsRateLimited`: Spiegelsprung 0,0073 gegen die Schranke 0,002).
- Scour-Deckel des Braid-Passes als Rate: s. o., Playa 100 → 35 Zellen.
- Tropfen-Index nur mit `index · 2654435761` gemischt: die gewichtete Luv/Lee-Drainagedichte fiel von ×1,14 auf ×1,01, obwohl Randverteilung und Serienkorrelation unauffällig waren. Mit Finalizer und Aufwärm-Zug ×1,21.
- Sättigung der Stream-Map vor der Mittelung: dt-abhängig, ein Einzelbesuch saturierte bei kleinen Schritten sofort, Zufallspfade so hell wie Flüsse.

Folgen: `dropsEmitted` und `dropCarry` gehören zum Spielstand. Der zweite benannte Rest neben dem Braid-Scour ist die Operator-Splitting-Drift (`docs/dt-invariance-measurements.md` §5).

Betrifft: `Terrain.relaxFraction`, `Terrain.stepCapFraction`, `Terrain.braidPass`, `SimConfig.braidDeltaCeiling`, `Terrain.dropCarry`, `Terrain.dropsEmitted`, `Terrain.streamMap`, `Terrain.streamRate`, `Hydraulic.erode`, `Hydraulic.dropRNG`, `Hydraulic.spawnPosition`
