# Generierung: Einlauf und Zurücksetzen einer bestehenden Welt

`generate(seed:settleYears:)` mit `settleYears > 0` lässt echte Sim-Physik laufen und stellt die Uhr danach auf Jahr 0 zurück (PR #106): die Welt ist eingelaufen (Kerben und Nadeln des rohen Reliefs entschärft), gilt aber als neu. Der Default 0 bleibt bit-identisch zum Stand ohne den Parameter.

`generate` auf einem bestehenden, gealterten Terrain (im Spiel: neuer Seed auf demselben `SimNode`) muss dieselbe Landschaft liefern wie ein frisches Terrain mit diesem Seed. Daran hängen die Aufräum-Zeilen in `generate` (Kryo-Felder, Becken-Bilanz, Baustellen, Zähler); bliebe eines stehen, entschiede nicht mehr der Seed allein über Relief und Entwässerung. Höhen, Sediment, Regen und Stream-Map sind bit-gleich.

Ausgenommen ist derzeit `veg` (mit `vegClass`/`riparian`), s. das zugehörige Issue: `generate` leert das Feld nicht, und der Sukzessions-Pass liest über den Samen-Druck (`vegDispersalRadius`) das vorhandene Feld (gemessen n = 96, Seed 1337 → 7: 1049 von 9216 Zellen unterschiedlich).

Betrifft: `Terrain.generate(seed:settleYears:)`, `TerrainAPITests.testGenerateResetsAnAgedTerrain`, `TerrainAPITests.testGenerateSettleRunsRealPhysicsAndResetsTheClock`
