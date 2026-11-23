# Auen-Aggradation pro Zelle ist abgeschaltet; die Aue kommt aus dem Mäandergürtel

Die Überflutungs-Aggradation (`floodplainAggradation`) sollte flache Auenböden bauen: Flüsse lagern seitlich ab (Overbank-Deposition), füllen nur tal-nahe Zellen bis knapp über Bett-Niveau, steile Talwände bleiben unberührt. Ohne Aue sind Talböden zu schmal (V-Täler) für sichtbare Fluss-Dynamik.

Der Pass ist AUS (`floodplainEnabled = false`): die per-Zell-Aggradation fügte feine Krusten hinzu (gemessen 2,7× Zerklüftung bei 3000 Jahren) für unbestätigten Auen-Nutzen. Seit Issue #174 entsteht die Aue stattdessen aus der lateralen Planation des Mäandergürtels (`meanderBelt`: Gleithang-Bank gedeckelt auf bankfull, gemessen glatter als vorher, `docs/zielbild-measurements.md` § Paket B).

Kalibrierung des geparkten Passes: `floodplainMinArea` 500 Zellen, nur Hauptflüsse bauen Auen. 60 verworfen: jedes Rinnsal baute Levees → Krusten-Rauschen; Bergbäche haben real keine Aue. `floodplainMaxElev` 0,50: Schwemmebenen sind Tiefland-Features.

Betrifft: `SimConfig.floodplainEnabled`, `SimConfig.floodplainMinArea`, `SimConfig.floodplainMaxElev`, `Terrain.floodplainAggradation`, `SimConfig.meanderBelt`
