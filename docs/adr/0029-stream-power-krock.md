# Stream-Power-Konstante kRock wirkt nur im Testpfad

Modell der Grid-Inzision: detachment-limited FastScape, `dz/dt = U − K·A^m·S^n` mit n = 1, implizit gelöst und damit unbedingt stabil.

`kRock` steht nur in `transportLimited`, dem Nicht-Droplet-Zweig (`hydraulicEnabled = false`), den nur die Mäander-Kopplungstests fahren (mit eigener gepinnter Konfiguration). Im Produktionspfad wirkt die Konstante gar nicht; die fluviale Rate der Produktion ist `outletErode`. Bei #10 (gewichteter Abfluss) gemessen: kRock 3,5e-5 → 4,9e-5 (die aus #9 §D.2 gerechnete Kompensation ×1,4) ändert an n = 832/Seed 1337 über 20k Jahre KEINE Kennzahl — Kanalzellen 16329/25258/27184, Relief 0,5957/0,5312/0,4981 identisch mit dem Default-Lauf. Wer an der fluvialen Rate der Produktion drehen will, dreht an `outletErode`, nicht an `kRock`.

Betrifft: `SimConfig.kRock`, `SimConfig.mExp`, `Terrain.transportLimited`, `SimConfig.outletErode`
