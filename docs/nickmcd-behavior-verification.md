# Verhaltens-Abgleich mit nickmcd „Procedural Hydrology"

Referenz: https://nickmcd.me/2020/04/15/procedural-hydrology/ (Partikel-Hydrologie:
Stream-Map aus zeitgemittelten Tropfen-Pfaden, Pool-Map mit Flood/Drain-Zyklus,
Kopplung Karten→Partikel = River Sharpening).

Ziel (User): Terrain und Flüsse sollen sich **wie dort** verhalten. Diese Tabelle
hält je Referenz-Verhalten fest, WIE es in SimCore umgesetzt ist und WOMIT es
belegt ist (headless Test bzw. Screenshot). Stand: 2026-07-27.

| nickmcd-Verhalten | Umsetzung in SimCore | Beleg |
|---|---|---|
| Stream-Map = zeitgemittelte Partikel-Pfade, altes verblasst (lrate) | `Terrain.streamMap`: EWMA (τ≈3000 J., dt-invariant) der reife-gewichteten Tropfen-Besuchs**rate**; Sättigung erst nach der Mittelung (`streamRefRate`) | `testStreamMapMarksAndPersists`: Recall der großen Läufe > 0.4, Persistenz-Jaccard(+2k J.) > 0.35 |
| River Sharpening: Karten koppeln in Partikel zurück, etablierte Pfade werden bevorzugt | `HydraulicParams.streamEvapDamp`: Verdunstung ×(1−0.5·stream) auf etablierten Läufen → Tropfen leben dort länger; plus Carving-Feedback (Tropfen folgen eingeschnittenen Betten) | dito (Persistenz statt Springen); visuell: scharfe Fluss-Fäden statt Sheet-Wash |
| Tropfen leben bis zur Mündung | `maxSteps` 64→192 (64 starb auf halbem Hang; Unterläufe bekamen nie Tracks) | Recall-Assert; Screenshots: durchgängige Läufe bis zur Küste |
| Descend→Flood→Drain: Tropfen endet im Pool, Pool entwässert über Auslass, Partikel läuft dort weiter (Sediment −90%) | Pool-Interaktion in `Hydraulic.erode`: bei hf−h > `poolDepth` Sediment als **Delta** am Eintritt deponieren, Empfänger-Kette zum See-Auslass springen, mit `poolSedimentKeep`=10% weiterlaufen | Becken-Test + visuell (Flüsse laufen in Seen hinein und am Auslass weiter) |
| Diskrete Seen auf verschiedenen Ebenen, entwässern ineinander/zum Meer | Generierungs-**Breach** (`breachEnabled`): outletIncision-Spin-up (Trunk-gated, A≥100 Zellen) schneidet Becken-Sillen VOR Spielbeginn (antezedente Täler); Weltrand = Basisniveau Meer (Fix: Rand-Zellen ohne Empfänger erodieren gegen `sea`, sonst unerodierbarer Pegel) | `testBasinsDrainToSea` (Seeds 1337/42/2024): See-Anteil ~26% → ~4% bei Generierung, größter See < 3% des Landes |
| Seen füllen sich UND leeren sich (dynamisch) | Ergibt sich aus Droplet-Deposition (dämmt) vs. outletIncision (schneidet) — bewusst NICHT weggeregelt | dito: tiefer See oszilliert (z. B. Seed 42: 4 ↔ 955 Zellen über 10k J.), Assert: Minimum über den Lauf klein (= entwässert periodisch); Screenshot-Sequenz Jahr 8000→8800: Kratersee schrumpft sichtbar |
| Flüsse vereinigen sich zu Hauptläufen | D8/MFD-Drainage + Tracks | Screenshots (alle Seeds) |
| Braided Washes / Fäden in Flachbereichen, Deltas | MFD-Dispersion auf flachen subaerischen Läufen (`braidDispersion`, Quinn 1995) + Murray&Paola-`braidPass` (qcᵢ = Kb·Q·Sᵢ·fᵢ^2.5) + Pool-Delta-Deposition. Kb=1e-5: ERGÄNZT die Droplet-Dynamik (3e-5 übertönte sie — Droplets bauen seit der Pool-Kopplung selbst Bänke) | `testBraidingBuildsBars`: Inseln bilden UND schließen sich (Summe 7 vs. 5 ohne Pass, Splits 433 vs. 325) |
| Bäume/Vegetation dämpfen Erosion | `veg`-Feld dämpft alle Erosionspfade ((1−0.6·veg)) — war schon da | Bestands-Tests |

## Bewusste Abweichungen von der Referenz

- **Kein persistentes Wasser-Volumen je Pool**: nickmcd füllt Pools aus Partikel-
  Volumen (`volumeFactor`); wir nehmen den Priority-Flood-Spiegel (hf) als
  Gleichgewichts-Pegel. Das Füllen/Leeren entsteht bei uns morphologisch
  (Dämme/Sillen), nicht volumetrisch. Sichtbares Verhalten ist äquivalent
  (Seen wachsen/schrumpfen), die Zeitskala ist geologisch statt hydrologisch —
  passend zum Zeitraffer-Spiel.
  **Teilweise aufgehoben (Issue #11):** der Spiegel ist nicht mehr
  bedingungslos das Sill-Niveau. Ein geschlossenes Becken bekommt einen
  Wasserhaushalt — Zufluss (niederschlagsgewichteter Abfluss aus #9/#10) gegen
  Verdunstung über der Seefläche (`Terrain.capEndorheicBasins`) — und steht unter
  der Sill, wenn der Zufluss den Vollstand nicht trägt. Das ist keine
  Volumen-Bilanz je Partikel, sondern ein Flächen-Gleichgewicht je Becken
  (stationär, ohne Speicher), aber es macht endorheische Becken, Playas und
  Salzseen erstmals möglich. Ein verdunstungs-limitiertes Becken ist eine
  TERMINALE Senke: kein Sill-Abfluss, keine Auslass-Inzision — es entwässert sich
  also nicht selbst frei. Belege: `docs/endorheic-evaporation-measurements.md`,
  Wächter `EndorheicEvaporation`.
- **Erosion zusätzlich über FastScape/outletIncision**: die Makro-Täler kommen
  weiter aus der (stabilen, kalibrierten) Grid-Inzision; nickmcds reine
  Partikel-Erosion übernimmt Textur + Hydrologie-Karten. Grund: Terrain-Look
  war bereits abgenommen und soll nicht kippen.
- **Murray&Paola-braidPass** ist eine Ergänzung, die nickmcd nicht hat (User-
  Task #4 Verflechtung); seit der Pool-Kopplung liefern die Droplets einen Teil
  der Bänke selbst, der Pass ist darauf herunterkalibriert (Kb 3e-5→5e-6).

## Messwerte (n=256, Seed 1337, Stand 2026-07-27)

- See-Anteil bei Generierung: 4.3% (ohne Breach 26.5%), größter See 782 Zellen.
- Unter Simulation: flaches Ponding oszilliert 7–12%, tiefer See min→0 (entwässert).
- Braiding: Insel-Summe 9 (an) vs. 4 (aus), Splits-Max 336 vs. 260, transient.
- Stream-Map: Recall große Läufe ~0.4+, Persistenz-Jaccard(+2k J.) 0.28.
- FPS Zeitraffer 60 J/s: ~20 (Idle ~83) — Droplets (maxSteps 192) dominieren.

Screenshots der Verifikation liegen im Session-Scratchpad (`final2_*`, `dyn_*`).
