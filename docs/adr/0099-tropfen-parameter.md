# Kalibrierung der Tropfen-Hydraulik und Kopplung an Kanal und Seen

Die Droplet-Erosion (nach Sebastian Lague / nickmcd) carvt feine dendritische Rinnen. Ihre Parameter liegen in `HydraulicParams` neben dem Code; `SimConfig` überschreibt nur `inertia` (0,10). Bedeutung der Grundparameter: `inertia` 0 = folgt dem Gradienten, 1 = Richtung bleibt; Kapazität ∝ Steigung·Geschwindigkeit·Wasser, `minSlope` verhindert Stagnieren; `erodeRate`/`depositRate` sind Anteile des Kapazitätsdefizits bzw. -überschusses; `evaporate` ist Wasserverlust je Tropfen-Schritt; `erodeRadius` ist der Pinselradius für weiche Rinnen.

## `maxSteps` = 144

Von 64 erhöht (nickmcd: Tropfen leben bis zur Mündung). Mit 64 starben Tropfen auf halbem Weg den Hang hinunter; die Unterläufe großer Flüsse bekamen nie Tropfen (keine Tracks, kein Carven der Auen-Ebenen). 192 kostete ~25 % mehr ohne sichtbaren Zugewinn.

## nickmcd-Kopplung (Procedural Hydrology)

- `streamEvapDamp` 0,5: Verdunstung × (1 − damp·stream). Auf etablierten Läufen leben Tropfen länger, Flüsse verlängern und schärfen sich selbst (sein „River Sharpening", effR = evap·(1 − 0,2·stream) sinngemäß).
- `poolDepth` 0,03: ab dieser Wassertiefe (hf − h) gilt eine Zelle als See (gleich der See-Render-Schwelle `WaterRender.lakeRawWetDepth`). Der Tropfen deponiert dort sein Sediment (Delta), springt die Empfängerkette entlang zum Auslass und läuft weiter. Flacheres Ponding (Auen-Washes) behandeln Tropfen normal; sie sollen es carven und damit entwässern. 0,02 ließ Tropfen auf den Ebenen permanent teure Ketten-Sprünge machen (FPS-Einbruch).
- `poolSedimentKeep` 0,1: Sediment-Anteil, der den See überlebt (nickmcd: −90 % beim Drain).

## Kanalmaske: nur Deposition dämpfen (`channelDepositDamp` = 0,15)

Der Mäander-Kanal carvt sein Bett selbst (`Terrain.meanderStamp`); der Droplet-Pfad kannte die `isChannel`-Maske vorher nicht (nur der Grid-Pfad über `cfg.channelErodeDamp`), in Produktion arbeiteten Kanal und Tropfen gegeneinander. Gemessen (n=256, 3 Seeds, 40k + 150k J., Bett-Tiefe gegen die Aue, `testChannelBedSurvivesDroplets`): nur die DEPOSITION ist der Konflikt, sie schüttet das Bett zu (14–15 % der Betten lagen über ihrer Aue). Die Tropfen-EROSION im Bett zieht in dieselbe Richtung wie der Carve; ihre Dämpfung machte das Bett flacher (+0,0147 → +0,0116) und die Verlandung schlimmer (8,7 % → 12,7 %). Deshalb gibt es bewusst kein Erosions-Pendant zu `channelErodeDamp`.

Der nicht abgelegte Rest bleibt in Suspension (Massenbilanz); der Kanal transportiert das Sediment weiter, statt zu verlanden. 0,0 ist instabil: der Tropfen dumpt seine Gesamtlast am ersten Nicht-Kanal-Hindernis, es entstehen Halden und Relief-Runaway (150k J.: relief 1,22, maxH 1,37). 0,15 und 0,10 sind messgleich; 0,15 hält Abstand zu dieser Kante.

Betrifft: `HydraulicParams`, `HydraulicParams.maxSteps`, `HydraulicParams.streamEvapDamp`, `HydraulicParams.poolDepth`, `HydraulicParams.poolSedimentKeep`, `HydraulicParams.channelDepositDamp`, `SimConfig.hydraulic`, `Hydraulic.erode`
