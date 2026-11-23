# Kanalmaske wirkt im Droplet-Pfad, opt-in und ohne Maske bit-identisch

Die `isChannel`-Maske wirkt im Produktions-Pfad (`hydraulicEnabled`). Vorher kannte sie nur der Grid-Pfad (`transportLimited`), und die Tropfen schütteten das gecarvte Mäanderbett wieder zu. Der Wächter vergleicht gegen die ungedämpfte Referenz (`channelDepositDamp = 1.0`, Zustand vor der Kopplung), gleicher Seed, über die Zeit gemittelt.

Gemessen (n=256, Seed 1337, 20k J.): Bett-Tiefe +0.0156 → +0.0222 (+43 %), verlandete Betten 7,3 % → 3,5 %. Über 3 Seeds × 150k J. konsistent (Tiefe +25…+57 %, Verlandung 13–15 % → 7–10 %), Relief und maxH unverändert. Schranken mit Marge: Tiefe > 1.20 × Referenz (gemessen ×1.43, ×1.25…1.57 über 3 Seeds), Verlandung < 0.75 × Referenz (gemessen ×0.48).

Ohne Maske (leeres Array) rechnet `Hydraulic.erode` bit-identisch wie vor der Kopplung.

Betrifft: `Hydraulic.erode`, `HydraulicParams.channelDepositDamp`, `Terrain.isChannel`, `RiverDynamicsTests.testChannelBedSurvivesDroplets`, `RiverDynamicsTests.testDropletUnchangedWithoutMask`
