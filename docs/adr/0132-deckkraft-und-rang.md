# Deckkraft und Strahler-Rang der Fluss-Bänder

Die Deckkraft eines Fluss-Bands setzt sich je Stützpunkt zusammen aus Abfluss-Rampe (weich auslaufen statt harter `renderMinCells`-Kante), Stream-Map-Kohärenz des ganzen Kanals (verwaiste, verknäulte Linien als Einheit ausblenden) und einem Boden über den Strahler-Rang.

Strahler-Rang: D8-Netz ab Mäander-Schwelle, als Rang-Maß der Render-Hierarchie; hohe Ordnungen bleiben sichtbar, wo die Abfluss-Rampe allein sie ausblenden würde. Er wird je Build frisch berechnet: `computeFlow` ändert Empfänger und `area`-Netzmaske auch ohne Knoten-Cutoff, ein Cache nur nach Mäander-Struktur wäre fachlich alt. Die Allokationsrate begrenzt der 1-Hz-Band-Deckel in `RenderState` (`ribbonRebuildSeconds`, für Zeitraffer und Sprung-Chunks).

Stützsaum: D8 und Lagrange-Zentrumslinie liegen nicht zellgenau übereinander. Ein 1-Zellen-Stützsaum (3×3-Maximum) verhindert, dass ein Band beim Überqueren EINER Zellgrenze zwischen Ordnung 3/4 komplett ein- oder ausblendet (räumliche Hysterese ohne Zustand).

Stream-Map bilinear: die Zentrumslinie ist kontinuierlich, die Sichtbarkeit wird ebenso bilinear gelesen. Nearest-Cell erzeugte bei Zellwechseln einzelne Alpha-Spitzen (sichtbare Dreiecksfächer). Gelesen wird mit demselben Fenster wie der Korridor-Stempel des Rasters (`WaterRender.corridorMask`, #51): beide fragen, ob dem gestempelten Bett real Wasser folgt.

Kanal-Ebene: die Stream-Map entscheidet über den ganzen Kanal. Lokale Raster-Spitzen als Alpha erzeugen isolierte Dreiecksfächer; ein kohärent durchflossener Kanal bleibt als ganzes Band sichtbar, inklusive Oberlauf. Abfluss-Vertrauen (#174 C2, `WaterRender.ribbonTrust`): ein großer Lauf bleibt sichtbar, auch wenn die Stream-Map ihn nicht trackt, je Stützpunkt, damit sein feiner Oberlauf an der Stütze hängt.

Kaskaden-Übergabe (`WaterRender.cascadeWeight`): an Steilstrecken blendet das Band aus, dort malt das Raster, dessen Deckel im Wasserfeld über DIESELBE Funktion entfällt. Ein 3D-Band verliert an Kaskaden gegen das Render-Mesh (Zacken statt Lauf). Zwei Pässe: lokale Neigung (±2 Samples ≈ 1 Zelle), dann MAX-Dilatation ±4 Samples (~2 Zellen). Stufenbecken sind selbst eben, gehören aber zur Kaskade; ohne die Dilatation blieben ihre flachen Band-Platten als Brocken zwischen den ausgeblendeten Abstürzen stehen (Steillauf-A/B). Das geschieht vor der Glättung, damit der Übergang weich ausläuft.

Längs-Glättung: diskrete Strahler-Zellen erzeugen an Netz-Kreuzungen Sprünge. Symmetrischer Kastenfilter ±6 Samples (~±3 Zellen): keine zeitliche Verzögerung, längere aktive Abschnitte bleiben unverändert.

Kartografische Hierarchie: nur Zentrumslinien, die wenigstens Strahler 3 erreichen (`WaterRender.ribbonMinimumRank`, Historie und Messung dort); der feine Oberlauf desselben Bands bleibt vollständig.

Rang für die Tiefenfarbe fällt stromab nie (laufendes Maximum von der Quelle zur Mündung): die Strahler-Ordnung eines Laufs wächst nur an Zusammenflüssen. Der 3×3-Stützsaum überbrückt nur einen Zellversatz; driftet die Linie weiter weg, fiel EIN Stützpunkt auf Rang 0 (oder ein Stück auf Ordnung 2), und der Shader malte über die volle Bandbreite einen hellen Querstrich („Leitersprosse", Seed 1337, Jahr 230.000: 0,667 → 0 → 0,667 an einem Stützpunkt). Gate und `river_ribbons.gd` lesen das Maximum des Bands, das bleibt unverändert.

Betrifft: `RiverRibbonRenderer.build`, `Terrain.strahlerOrders`, `WaterRender.corridorMask`, `WaterRender.cascadeWeight`, `WaterRender.ribbonTrust`, `WaterRender.ribbonMinimumRank`, `WaterRender.ribbonSupportLo`, `RenderState.ribbonRebuildSeconds`
