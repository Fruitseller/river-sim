# Zwei Entwässerungsnetze: D8 für die Erosion, MFD für Render und Braiding

D8 (`Terrain.area`) speist die Erosion; MFD (`Terrain.areaMFD`, Freeman 1991, Gewichte fᵢ = Sᵢᵖ/ΣSⱼᵖ) speist nur Rendering und Braiding. So bleiben der kalibrierte Terrain-Look und die implizite Stabilität der Erosion unangetastet. Beide Netze tragen dieselbe Gewichtung (`seedFlowAccumulator`, `flowWeight`), und `order` (aufsteigende Füllhöhe) ist für beide eine gültige topologische Ordnung.

MFD hat zwei Wirkungen, die D8 nicht haben kann: An einer Mittelbank bekommen beide Flanken S > 0, der Lauf teilt sich und vereint sich stromab (mit D8-argmax unmöglich). Und die Gewichte sind stetig in der Topografie, der Lauf gleitet bei kleinen Änderungen, statt auf einen anderen Nachbarn zu kippen (gemessen ~27 % Churn je Flow-Update unter D8, das „Springen").

Der lokale Exponent (Quinn 1995, abflussabhängig) steht an einer Stelle, `mfdLocalExponent`, für Wasser (`computeMFDArea`), Sediment (`braidPass`) und die Test-Metriken, damit die Fracht exakt dem Wasser folgt. Dispersiv (`braidDispersion`) nur auf großen, flachen, subaerischen Läufen; Hänge behalten `mfdExponent` (dendritischer Look), geflutete Beckenböden ebenso (Dispersion dort ergibt Sheet-Flow-Konfetti im Render).

Braiding ist der Erosions-Konsument des MFD-Felds. `braidPass` baut Mittelbänke und Fäden nach dem Minimalrezept von Murray & Paola (Nature 371, 1994): Wasser, das sich lateral aufteilen kann, plus Bedload mit superlinearer Kapazität `qcᵢ = Kb·dt · Q·Sᵢ · fᵢ^m`, m ≈ 2,5. Der stärkere Faden transportiert überproportional, scourt sich ein und fängt beim nächsten `computeFlow` mehr Wasser; unterversorgte Zellen lagern ab, Bänke wachsen bis knapp über den Wasserspiegel (`braidBarHeight`).

Die Superlinearität liegt auf der lateralen Partition fᵢ, nicht auf Q, das über das Netz drei Dekaden spannt: für festes Q trägt ein Faden (f = 1) mehr als zwei halbe (2·0,5^m ≈ 0,35), das ist die Konzentrationsinstabilität. Wo sich der Lauf aufspreizt (Σfᵢ^m ≪ 1), kollabiert die Kapazität, Deposition genau in breiten, flachen Reaches.

Reach-Gate: `areaMFD ≥ braidMinCells`, subaerisch, nur seicht überströmt (`hf − h < 0,015`). Bänkebau in tieferen Ponds und Seen macht die Beckenböden um die See-Render-Schwelle (0,03) rau, sichtbares Speckle statt Verflechtung. Vegetation dämpft den Scour (`vegDamp`), kohäsive Ufer verflechten real nicht.

Verworfen:
- MFD auch für die Erosion: verschöbe den kalibrierten Look und die implizite Stabilität der D8-Erosion.
- Braiding auf D8: kein Lauf kann sich an einer Bank teilen.
- Der explizite laterale Sedimentterm aus Murray & Paola: die radiale MFD-Verteilung (bis 8 tiefere Nachbarn) übernimmt die Querstreuung, Bänke entstehen nachweislich (`testBraidingBuildsBars`).

Deckel des Braid-Passes und ihre Schrittweitenabhängigkeit: ADR 0005.

Betrifft: `Terrain.area`, `Terrain.areaMFD`, `Terrain.computeMFDArea`, `Terrain.mfdLocalExponent`, `Terrain.seedFlowAccumulator`, `Terrain.braidPass`, `SimConfig.braidMinCells`, `SimConfig.braidBarHeight`
