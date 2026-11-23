# Braiding nach Murray & Paola mit Superlinearität auf der Partition

`braidPass` baut Mittelbänke und Fäden auf großen Läufen nach dem Minimalrezept von Murray & Paola (Nature 371, 1994): Wasser, das sich lateral aufteilen kann (MFD-Feld), plus Bedload mit superlinearer Kapazität `qcᵢ = Kb·dt · Q·Sᵢ · fᵢ^m`, m ≈ 2.5. Der stärkere Faden transportiert überproportional, scourt sich ein und fängt beim nächsten `computeFlow` mehr Wasser; unterversorgte Zellen lagern ab, Bänke wachsen bis knapp über den Wasserspiegel (`braidBarHeight`), der Lauf teilt sich und vereint sich stromab. Fracht geht ∝ Kapazität an die MFD-Empfänger.

Die Superlinearität liegt auf der lateralen Partition fᵢ, nicht auf Q, das über das Netz drei Dekaden spannt: für festes Q trägt ein Faden (f = 1) mehr als zwei halbe (2·0.5^m ≈ 0.35), das ist die Konzentrationsinstabilität. Wo sich der Lauf aufspreizt (Σfᵢ^m ≪ 1), kollabiert die Kapazität, Deposition genau in breiten, flachen Reaches. Der explizite laterale Sedimentterm aus M&P entfällt: die radiale MFD-Verteilung (bis 8 tiefere Nachbarn) übernimmt die Querstreuung, Bänke entstehen nachweislich (`testBraidingBuildsBars`).

Reach-Gate `areaMFD ≥ braidMinCells`, subaerisch, und nur seicht überströmt (`hf − h < 0.015`): tiefere Ponds und Seen nicht, Bänkebau dort macht die Beckenböden um die See-Render-Schwelle (0.03) rau, sichtbares Speckle statt Verflechtung. Vegetation dämpft den Scour (`vegDamp`), kohäsive Ufer verflechten real nicht. Kapazität und Fracht skalieren mit dt. Bewegt wird nur, was der Pass selbst scourt.

Depositionsdeckel als geometrische Obergrenze `hf + braidDeltaCeiling` statt als Zugabe je Schritt (Issue #2). Vorher stand `max(0, hf − h) + 0.005`, der Aufschlag also über dem aktuellen h: nach Erreichen des Spiegels setzte jeder Schritt nochmal 0.005 drauf, der Uferaufbau wuchs mit der Schrittzahl statt mit der Zeit. Warum 0.05 und nicht `braidBarHeight`: Logbuch bei `SimConfig.braidDeltaCeiling`.

Der Scour-Deckel bleibt bei festen 0.5 der lokalen Differenz je Schritt (nicht `stepCapFraction`): Issue #2 betraf die Depositionsdeckel. Als Rate dürfte ein 200-Jahr-Schritt 0.75 statt 0.5 ausräumen; der Braid-Scour grub dann die Böden abflussloser Becken tiefer, die verkrustete Playa-Fläche fiel von > 100 auf 35 Zellen, und `testDriedBedIsRenderedAsPlaya` sowie `testBasinLevelIsRateLimited` kippten (`docs/dt-invariance-measurements.md` §5/§6). Das ist eine bekannte Schrittweitenabhängigkeit (s. #275).

Betrifft: `Terrain.braidPass`, `SimConfig.braidDeltaCeiling`, `SimConfig.braidBarHeight`, `SimConfig.braidMinCells`
