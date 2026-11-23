# Generierung: frischer Zustand, kurzer Einlauf, eingeschwungener Start

`generate(seed:settleYears:)` ruft zuerst `resetToAllocated` auf, das alle Zustandsfelder und Puffer auf den Stand eines frisch allokierten Terrains setzt (#174). Vorher überlebten u. a. `isChannel`, Vegetation und Stream-Map, und Seed 42 im Spiel war eine andere Welt als in jeder Messreihe. Wer ein Feld hinzufügt, setzt es dort zurück (Wächter `FingerprintTests.testGenerateOnUsedTerrainYieldsFreshWorld`).

Das Gesteinsfeld entsteht vor dem ersten Flow: Becken-Breach und Spin-up-Tropfen sollen die Härtekontraste schon sehen, die antezedente Entwässerung ist so von Anfang an strukturkontrolliert.

Startzustands-Doktrin: was älter ist als Spieljahr 0, startet eingeschwungen statt über die ersten Jahrhunderte einzuschwingen.
- Becken-Wasserhaushalt: `computeFlow` mit dt = 0, der Bilanz-Spiegel snappt auf sein Ziel.
- Klima: `updateClimate(dt: 10000)`; das sind bei der trägsten Zeitkonstante (`snowTurnoverYears` 500) 20 τ, der Vorrat steht exakt auf S*. Muss vor `updateVegetation` laufen, dessen `updateHeightBands` die Schneegrenze aus dem Feld liest.
- Vegetation: `updateVegetation(years: 10000)`.
- Seespiegel: `waterLevel = hf`.
- Playas starten mit voller Kruste; sonst salzt eine seit der Generierung trockene Pfanne erst über ~1200 Jahre ein.
- Stream-Map: einige Tropfen-Chargen laufen das frische Terrain hinab (`spinUpStreamMap`), sonst wären anfangs keine Flüsse sichtbar.

Einlauf (`settleYears > 0`, PR #106): die frische Welt läuft so viele Jahre echte Sim-Physik und die Uhr wird danach auf 0 gestellt. Das rohe Noise- und Pre-Erosions-Relief ist ein unphysikalischer Extremzustand (gestanzte Kerben-„Krater", Nadelgrate; auf dem 720er-Grid Gratkrümmung ≈ −0.88 gegen ≈ −0.03 bei 100k, Faktor 27; kalibriert war die Alterung auf n=160 mit Faktor 2). Ein kurzer Lauf der Pässe, die danach ohnehin laufen, entschärft genau diese Formen; junge und gealterte Welt sprechen dieselbe Formensprache. Default 0, damit SimCore-Testwelten und Kalibrier-Messreihen unverändert bleiben; den Produktionswert setzt `SimConfig.productionSettleYears`. Der Einlauf läuft vor den Startzustands-Doktrinen, damit Seespiegel und Kruste den eingelaufenen Stand einfrieren, und ist getaktet wie der Zeitraffer (1000-Jahr-Chunks). Danach werden die Geburtsjahre der Mäander-Strecken (`born`) gelöscht; sie lägen sonst in der Zukunft und eingesetzte Strecken blieben bis ~Jahr 2200 unsichtbar.

Betrifft: `Terrain.generate`, `Terrain.resetToAllocated`, `Terrain.spinUpStreamMap`, `Terrain.buildLithologyField`, `SimConfig.productionSettleYears`
