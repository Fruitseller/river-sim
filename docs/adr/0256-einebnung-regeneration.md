# Großflächige Einebnung regeneriert sich (#26)

Der Report zeigte nach großflächigem Einebnen eine über Zehntausende Jahre uniforme, dicht bewaldete Platte ohne neues Entwässerungsnetz. Alle Wächter laufen über die echte Pinsel-API (`Terrain.flatten`) mit den UI-Grenzwerten (Radius 30 Welteinheiten = Maximum des Radius-Reglers in `Main.gd`, Stärke 3), kein direktes Beschreiben von `h`, sonst prüft der Test einen Pfad, den der Spieler nie auslöst. Messreihen: `docs/flatten-regeneration-measurements.md`.

Gemessen wird auf der Innenfläche (Rand 16 Zellen weg): Am Weltrand ist das Basisniveau Meer, dort schneidet die Inzision auch ohne Regeneration eine Schlucht (max−min 0,21 nach 3000 J. auf der unbehandelten Platte). Die Frage ist, ob sich die Fläche differenziert. Gegenprobe im selben Test: derselbe Eingriff mit abgeschaltetem Regenerations-Pfad = Zustand aus dem Report.

Kriterien und Messwerte (Seeds 1337/4242/777, nach 3000 Jahren, mit gegen ohne Pfad):
- Hoch- und Talseitenrelief zusammen (Kriterium 6: beide Hälften getrennt, je nach Seed differenziert sich die Fläche nach oben oder unten): 0,065/0,086/0,065 gegen 0,009; Schranke > 0,04 und > 3× ohne Pfad.
- Makro-Steigung (die Größe, die Vegetation und Biom-Farbe lesen): 0,0055/0,0037/0,0033 gegen 0,0005; Schranke > 0,002 und > 3×.
- Eingeschnittene Zellen: 31 %/16 %/20 % gegen exakt 0 %; Schranke > 8 % und +5 Punkte.
- Sukzession statt Waldtapete: direkt nach dem Eingriff kahl, nach ~500 Jahren Gras, erst danach Wald, als Mosaik.
- Kriterium 2: stark veränderte Zellen verlieren Vegetation und Stream-Map-Gedächtnis der alten Topografie (anteiliger Reset), unveränderte Bereiche nicht; mit dem Bestand fällt auch das Kronendach.
- Kriterium 3: Der Sofort-Effekt des Werkzeugs wird nicht verrauscht, die frisch gezogene Fläche ist exakt flach.
- Kriterium 5: Ohne Eingriff läuft die Alterung bit-identisch zum Stand vor #26; der Pfad ist ausschließlich Eingriffs-Folge.
- Mäander: Ohne Pfad schreibt die Sim den alten Zustand fort (14 → 14 Altarme, Sinuosität 1,665 → 1,622); mit Pfad 14 → 0 Altarme, Sinuosität 1,665 → 1,274. Ohne Pfad ist ein neuer Cutoff in 250 Jahren erlaubt (Linux-CI 17 → 18, seit der Gürtel nach #187 schneller wächst; macOS 17 → 17).

Framerate-Wächter: prüft die Teleskopierung des Regenerations-Budgets mit stillgelegten übrigen h-Pässen. Dazu gehört seit #35 der Gletscher: `updateIce` läuft am Schrittanfang auf dem Klima des vorigen Schrittendes, im ersten Schritt also auf den noch ungeebneten Gipfeln; dort entsteht einmalig Eis, das auf der warmen Platte (sea + 0,25, weit unter der Firn-Grenze 0,5731) ausschmilzt und eine Moräne ablegt. Die Menge hängt an dt (max. Abweichung 0,0018 zwischen dt 50 und 1000), dieselbe Operator-Splitting-Drift, wegen der `hillDiffusion` auf 0 steht; mit einer 1e-9-Schranke nicht messbar. Der Gletscher hat einen eigenen Framerate-Wächter (`Glacier.testIceIsFramerateIndependent`).

Betrifft: `Terrain.flatten`, `Terrain.regenerateDisturbed`, `Terrain.registerDisturbance`, `SimConfig.disturbanceEnabled`, `FlattenRegeneration`
