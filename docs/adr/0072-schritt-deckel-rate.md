# Schritt-Deckel als Rate: max(0.5, 1 − e^(−dt·ln2/500))

Mehrere Pässe deckeln ihren Eingriff auf einen Anteil der lokalen Höhendifferenz ("nicht unter den Empfänger graben", "nicht über den Innenhang schütten"). Dieser Anteil war fest 0.5 JE SCHRITT und damit dt-abhängig: viele kleine Schritte nehmen jedes Mal die Hälfte des Rests und kommen der Grenze beliebig nahe, ein großer Schritt bleibt bei der Hälfte stehen (Issue #2).

Der Fehler sitzt nur bei großem dt. Bei kleinem dt ist der feste Deckel richtig: der Eingriff ist ∝ dt und winzig, der Deckel greift nicht, und über viele Schritte nähert sich das Gelände der Grenze asymptotisch, das Kontinuums-Verhalten.

Deshalb `stepCapFraction(dt) = max(0.5, 1 − e^(−dt·ln2/500))`:
- dt ≤ 500 J.: exakt die alten 0.5. Die bestehende Kalibrierung (Mäander-, Altarm-, Becken- und Langlauf-Wächter takten mit dt ≤ 500) bleibt bit-genau.
- dt > 500 J.: der Deckel wächst weiter, 0.75 bei 1000, 0.94 bei 2000, 0.999 bei 5000. Ein 2000-Jahr-Sprung gibt praktisch dasselbe frei wie vier 500-Jahr-Schritte (1 − 0.5⁴ = 0.9375).

Verworfen: die reine Exponentialform ohne Untergrenze. Sie drosselt kleine Schritte künstlich (bei dt = 20 J. nur 0.027 statt 0.5) und verschob genau die Wächter, die in 20-Jahr-Schritten messen: `EndorheicEvaporation.testBasinLevelIsRateLimited` (max. Spiegelsprung 0.0073 gegen die Schranke 0.002) bzw., mit dem zuerst probierten Anker 100 J., `Lithology.testEndorheicMechanicsSurviveLithology`. Der Deckel gibt in jeder Variante nie mehr frei als die volle Höhendifferenz, der Eingriff kann nicht überschießen.

Bewusst NICHT über `Terrain.relaxFraction`: dort ist der Nenner die Zeitkonstante τ, hier die Halbwertszeit (500 J.). `relaxFraction(dt:, tau: 500/ln2)` wäre in Reellen dasselbe, aber nicht bitgleich, und die Zahl ist auf 0.5 bei dt = 500 kalibriert.

Ausnahme mit eigener Begründung: der Scour-Deckel in `braidPass` bleibt bei festen 0.5 (s. AGENTS.md, `docs/dt-invariance-measurements.md` §6).

Betrifft: `Terrain.stepCapFraction`, `Terrain.meanderStamp`, `DtInvariance.testStepCapsAreRates`, `docs/dt-invariance-measurements.md`
