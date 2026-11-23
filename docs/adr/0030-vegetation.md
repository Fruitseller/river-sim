# Vegetations-Typen, Flood-Kill und Sukzession ohne Verschiebung der Erosions-Kalibrierung

Typen (Stufe 2, Gras/Wald/Auwald): die Klassen kommen je Zelle aus veg + Flussnähe + Steigung (`Terrain.updateVegClass`) und verstärken die bestehende 0,6-Erosions-Dämpfung multiplikativ: Schutz = 1 − 0,6·typFactor·veg. Gras = 1,0 hält das bisherige Verhalten flächendeckend exakt (die 0,6 bleibt unangetastet, Kalibrier-Kaskade); nur Wald und Auwald schützen stärker.
- `vegTypeFactorForest` 1,1: 1,25 drückte im 50k-Vergleichslauf die Ruggedness sichtbar (Rinnen wuchsen zu).
- `vegTypeFactorRiparian` 1,3: kohäsivste Ufer (0,6·1,3 = 0,78 < 1, kein Vorzeichenwechsel möglich), bewusst spürbar über Wald, damit Ufer-Reaches sich von Hängen abheben.

Flood-Kill (Stufe 3): steht Wasser tiefer als `vegFloodKillDepth` 0,03 (die See-Render-Schwelle, substanzielles stehendes Wasser), stirbt der Bewuchs mit eigener schneller Zeitkonstante statt der trägen 250-a-Relaxation. Seichteres Ponding (überströmte Aue) tötet nicht, das drückt schon das veg-Ziel (hf − h > 0,015 → Ziel 0). `vegFloodKillYears` 20: nach ~60 J. (3τ) ist eine geflutete Fläche kahl; 250 ließ Wälder Jahrhunderte unter Wasser stehen.

Sukzession: Regrünung braucht Samen-Druck, das veg-Ziel wird um max(veg im Umkreis)·Strength angehoben, nur auf bewohnbaren Standorten (geografisches Ziel > 0,05; steile Hänge und Höhenwüste bleiben kahl). Störungsflächen neben intaktem Bewuchs regenerieren mit dessen Dichte als Ziel; freistehende Maxima strahlen nur mit 0,75-Abfall je 2-Zellen-Ring aus → begrenzte Säume statt uniformer Verwaldung. `vegDispersalStrength` 1,0 ließe Wald jede bewohnbare Zelle fluten.

Betrifft: `SimConfig.vegTypeFactorForest`, `SimConfig.vegTypeFactorRiparian`, `SimConfig.vegFloodKillDepth`, `SimConfig.vegFloodKillYears`, `SimConfig.vegDispersalRadius`, `SimConfig.vegDispersalStrength`, `Terrain.updateVegClass`, `Terrain.updateVegetation`
