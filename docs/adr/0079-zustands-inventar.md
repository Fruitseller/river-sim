# Zustands-Inventar: was eine Welt ist (Issue #8)

`TerrainState` ist die eine Stelle, an der steht, WAS eine Welt ist; die Kodierung (Magic, Version, Datei) macht `WorldSnapshot.swift`.

Aufnahmekriterium: jedes Feld, das ein `step()` liest, bevor es es schreibt, plus alles, was Rendering und Diagnose sofort nach dem Laden brauchen (Issue #8, Abnahmepunkt 5: kein Einschwingen des Seespiegels). Bewusst großzügig: auch Felder, die `computeFlow` im nächsten Schritt neu ableitet (`hf`, `receiver`, `area`, `areaMFD`, `order`, `floodParent`, `rain`, `rainWeight`, `lithHardness`, `lithErodeK`, `temperature`, `playaBed`, `endorheicBasin`, `endorheicInflow`), reisen mit. Dann ist "geladener Zustand == gespeicherter Zustand" feldweise prüfbar (`WorldSnapshotTests`), und der erste Frame ist ohne erzwungenen Sim-Schritt korrekt. Beispiel für "gelesen vor geschrieben": `riparian` liest der Mäander-Pass erst im nächsten Schritt.

Nicht aufgenommen sind reine Arbeitspuffer und abgeleitete Felder. Welche das sind und warum, steht seit Issue #98 an einer Stelle: `SimCoreTests/StateInventoryTests.classification` sortiert jede gespeicherte Eigenschaft als persistent, abgeleitet oder Scratch; eine nirgends einsortierte Eigenschaft macht den Wächter rot. Nicht gespiegelt: die Bin-Puffer des Mäander-Cutoff-Index in `MeanderState`, ebenfalls Arbeitsspeicher; `restore` baut deshalb einen frischen `MeanderState`.

`underIce` ist eine Ableitung aus `ice` und nicht im Inventar (#35). `restore` leert sie: der erste `updateIce` des nächsten Schritts baut sie neu, und bis dahin darf keine Maske eines anderen Terrains stehen bleiben.

`upliftBase`, `lithBed` und `lithProvince` sind streng genommen fix je Seed, reisen aber mit: `sculpt` koppelt in die Tektonik (`upliftBase` ist damit nicht mehr aus dem Seed ableitbar), und ein Nachbau per Noise-Code wäre eine zweite Wahrheit über "was ist eine Welt".

Die Becken-Rolle reist als Rohbytes (`BasinRole.rawValue`), so liegt das Feld im Schnappschuss (`WorldSnapshot.uint8Fields`).

Tropfen-Strom (Issue #2): `dropsEmitted` (laufende Nummer des nächsten Tropfens, legt über `Hydraulic.dropRNG` seinen Startpunkt fest) und `dropCarry` (angebrochener Tropfen) gehören zum Determinismus. Ohne beide liefe eine geladene Welt mit einem anderen Tropfen bzw. bei Frame-Schritten mit einer anderen Tropfenzahl weiter als die durchgehend simulierte; genau das prüft `WorldSnapshotTests` bit-genau. Sie ersetzen den früheren Schritt-Zähler `stepCount`.

Betrifft: `TerrainState`, `Terrain.state`, `Terrain.restore`, `WorldSnapshot.swift`, `SimCoreTests/StateInventoryTests.swift`, `SimCoreTests/WorldSnapshotTests.swift`
