# Darstellungs-Seespiegel dämpft nur den Anstieg

`relaxWaterLevel` relaxiert den Darstellungs-Seespiegel ratenbegrenzt Richtung Füllstand, exponentiell in Sim-Zeit (Zeitraffer in Mini-Schritten und ein +10.000-J.-Sprung landen am selben Pegel), per-Zelle unabhängig und parallel, bit-identisch zur sequenziellen Schleife.

Gedämpft wird nur der ANSTIEG (der Sill-Plug des Sägezahns); fällt der Füllstand unter den Spiegel, folgt der Spiegel sofort. Bis Issue #174 relaxierte er in beide Richtungen, und auf trockenem Boden (hf = h) war er dann eine verzögerte Kopie des Geländes: jede Zelle, die schneller sinkt als τ, trug für Jahrhunderte einen Geister-See der Tiefe des Abtrags. Der Mäandergürtel gräbt sein Bett in ~10 Jahren eine Kanaltiefe tief (`meanderBeltRelaxYears`); gemessen (Seed 1337, Jahr 2300) lagen damit ~2600 Zellen mit Spiegel > hf + 0,01 auf trockenem Boden (hf-Säule 0,0005, Spiegel-Säule 0,02 ≈ 10 Bankfull-Tiefen), als fleckige, halbdurchsichtige Seen in den Schlingen und im Kanal (ohne Gürtel ~140; `docs/zielbild-measurements.md` § Geister-Seen im Mäandergürtel). Ein echter Pegelfall (Auslass schneidet sich frei) läuft über die Inzision ohnehin allmählich.

Die Physik liest `waterLevel` nicht; sie bleibt bit-identisch.

Betrifft: `Terrain.relaxWaterLevel`, `Terrain.waterLevel`, `SimConfig.lakeLevelResponseYears`, `docs/zielbild-measurements.md`
