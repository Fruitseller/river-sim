# Darstellungs-Seespiegel folgt `hf` ratenbegrenzt, nur beim Anstieg

Deposition am Becken-Auslass (Tropfen, Braiding, Mäander) schüttet den Sill zu, Priority-Flood hebt `hf` sofort fürs ganze Becken, und die Auslass-Inzision schneidet über ~100 Jahre zurück (Plug/Breach-Sägezahn). Der Darstellungs-Seespiegel `waterLevel` folgt `hf` deshalb ratenbegrenzt (`lakeLevelResponseYears`); der Wächter verhindert, dass jemand das Rendering zurück auf `hf` verdrahtet.

Schranke: je 20-Jahr-Schritt springt `waterLevel` höchstens um den Anteil `1 − exp(−20/250)` ≈ 0.08 der `hf`-Abweichung; 0.35 lässt Marge für echte langsame Pegeländerungen. Der Test pinnt die Großform vor #174 (`calibrationRangeLandform`), weil die neue Seed-1337-Welt über Täler entwässert und kein Becken über 500 Zellen hat.

Gedämpft wird nur der Anstieg (#174): fällt `hf`, folgt der Spiegel sofort. Vorher relaxierte er auch abwärts, und auf trockenem Boden (hf = h) war er eine verzögerte Kopie des Geländes; jede Zelle, die der Mäandergürtel binnen Jahrzehnten eine Kanaltiefe tief gräbt, trug Jahrhunderte lang einen fleckigen Geister-See (`docs/zielbild-measurements.md` § Geister-Seen im Mäandergürtel). Erosion senkt in jedem Schritt irgendwo trockenen Boden, die Invariante `waterLevel ≤ hf` bricht also sofort, wenn die Abwärts-Relaxation zurückkommt.

Betrifft: `Terrain.relaxWaterLevel`, `SimConfig.lakeLevelResponseYears`, `LakeLevelStability`
