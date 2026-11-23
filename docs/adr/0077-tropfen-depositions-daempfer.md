# Dämpfer der Tropfen-Deposition auf wasserführenden Läufen (Issue #108)

Auf gealterten Welten lag das Bett der Flüsse auf Umgebungsniveau, das Wasser schien auf dem Hang zu kleben. Gemessen (Kennzahl `ChannelIncision`, Quereinschnitt senkrecht zur Fließrichtung) kollabiert der Einschnitt in den ersten 25k Jahren um ~70 %, und die Kanalzellen steigen dabei absolut schneller als ihre Flanken: die Betten werden zugeschüttet. Ursache: im flachen Alters-Profil verliert der Tropfen Kapazität (`capacity ∝ Steigung·Speed·Wasser`, Boden `minSlope`) und lädt seine Fracht genau dort ab, wo er sie eben noch getragen hat.

Physisch fehlt dem Modell, dass ein wasserführender Lauf Fracht durchtransportiert; Alluvialflüsse exportieren ihr Bettmaterial zur Mündung. Präzedenz ist `HydraulicParams.channelDepositDamp`, das nur die Mäander-Maske (`isChannel`) kennt, also die wenigen Hauptläufe; dort dämpft sie die Deposition, damit die Tropfen das gecarvte Bett nicht wieder zuschütten. Die dendritischen Läufe, aus denen der Look besteht, hatten keinen Dämpfer.

Entscheidung: `buildDepositDamp` baut einen Dämpfer über den D8-Abfluss (Erosions-Netz, nicht MFD, s. Rollentrennung in AGENTS.md), in Zellen gemessen wie `braidMinCells`, mit smoothstep-Übergang. Auf Mäanderzellen gewinnt der stärkere der beiden Dämpfer. Der nicht abgelegte Rest bleibt beim Tropfen in Suspension und erreicht das Bett weiter unten oder das Meer. AUS (`flowDepositDamp = 1`) heißt leeres Feld und bit-identische Arithmetik zum Stand vor #108.

Der Dämpfer wirkt im Sim-Schritt, nicht im Tropfen-Spin-up der Generierung (`spinUpStreamMap`): dessen Charge bildet keine Zeit ab, sondern legt die erste Stream-Map auf das rohe Noise-Relief, in dem es noch kein Lauf-Netz gibt. Er behält seine kalibrierte Realisierung (dieselbe Begründung wie `firstDrop: nil` dort).

Betrifft: `Terrain.buildDepositDamp`, `Terrain.depositDampBuf`, `SimConfig.flowDepositDamp`, `HydraulicParams.channelDepositDamp`, `Hydraulic.erode`, `Terrain.spinUpStreamMap`
