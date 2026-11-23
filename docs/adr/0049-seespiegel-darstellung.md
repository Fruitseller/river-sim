# Darstellungs-Seespiegel folgt hf ratenbegrenzt, die Physik liest hf

Priority-Flood setzt `hf` instantan aufs Sill-Niveau. Jede Deposition am Beckenauslass (Tropfen, Braiding, Mäander; gemessen: keine Einzelquelle dominiert) ließ sonst die gesamte Seefläche im Render springen, und die Auslass-Inzision schnitt sie über ~100 Jahre wieder frei (Plug/Breach-Sägezahn). `waterLevel` folgt `hf` deshalb ratenbegrenzt (`lakeLevelResponseYears`); physisch füllt sich ein See mit endlicher Rate. Gedämpft wird nur der Anstieg: der Spiegel liegt nie über `hf`, sonst entstehen Geister-Seen auf frisch abgetragenem Boden (#174, `relaxWaterLevel`).

`waterLevel` ist nur fürs Rendering. Pools, Verlandung und Tropfen lesen weiter `hf`; ein träges Verlandungsziel war messbar wirkungslos und störte die Braid-Bänke.

Spieler-Eingriffe (Sculpt → `recomputeFlow`) setzen den Spiegel sofort auf den Füllstand (`snapWaterLevel`): ihr Feedback soll instantan sein, träge ist nur die Sim-Dynamik am Auslass.

Betrifft: `Terrain.waterLevel`, `Terrain.relaxWaterLevel`, `Terrain.snapWaterLevel`, `SimConfig.lakeLevelResponseYears`
