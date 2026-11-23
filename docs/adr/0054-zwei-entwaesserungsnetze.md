# Zwei Entwässerungsnetze: D8 für Erosion, MFD für Render und Braiding

D8 (`Terrain.area`) speist die Erosion; MFD (`Terrain.areaMFD`, Freeman 1991, Gewichte fᵢ = Sᵢᵖ/ΣSⱼᵖ) speist nur Rendering und Braiding. So bleiben der kalibrierte Terrain-Look und die implizite Stabilität der Erosion unangetastet. Beide Netze tragen dieselbe Gewichtung (`seedFlowAccumulator`, `flowWeight`).

MFD hat zwei Wirkungen: An einer Mittelbank bekommen beide Flanken S > 0, der Lauf teilt sich und vereint sich stromab (mit D8-argmax unmöglich). Und die Gewichte sind stetig in der Topografie, der Lauf gleitet bei kleinen Änderungen, statt auf einen anderen Nachbarn zu kippen (gemessen ~27 % Churn je Flow-Update unter D8, das „Springen").

`order` (aufsteigende Füllhöhe) ist auch für MFD eine gültige topologische Ordnung: jeder Ziel-Nachbar liegt tiefer in `hf`, von hoch nach tief ist `areaMFD[k]` vollständig gesammelt, bevor es verteilt wird.

Der lokale Exponent (Quinn 1995, abflussabhängig) steht an einer Stelle, `mfdLocalExponent`, für Wasser (`computeMFDArea`), Sediment (`braidPass`) und die Test-Metriken, damit die Fracht exakt dem Wasser folgt und die Gates nicht auseinanderlaufen. Dispersiv (`braidDispersion`) nur auf großen, flachen, subaerischen Läufen (Braid-Plains); Hänge behalten `mfdExponent` (dendritischer Look), geflutete Beckenböden ebenso (Dispersion dort ergibt Sheet-Flow-Konfetti im Render). Die Wert-Variante `mfdLocalExponent(a:sMax:pond:)` existiert für die Hot-Loops auf Roh-Puffern, die `self.areaMFD` nicht gleichzeitig lesen dürfen: eine Regel, zwei Aufrufer.

Betrifft: `Terrain.area`, `Terrain.areaMFD`, `Terrain.computeMFDArea`, `Terrain.mfdLocalExponent`, `Terrain.braidPass`
