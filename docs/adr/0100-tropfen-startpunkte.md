# Tropfen-Startpunkte: abflussgewichtet, je Tropfen eigener Zufallsstrom

Tropfen starten dort dichter, wo mehr abfließt, und jeder Tropfen ist unabhängig von der Schrittweite derselbe Tropfen. Beides ist gemessen und hat bit-identische Rückfälle.

## Gewichtung über `flowWeight`

Die Startpunkte lesen `Terrain.flowWeight` (Regen plus Schmelze seit #36), ausdrücklich nicht `Terrain.rainWeight`: die Tropfen-Starts sind einer der drei Abfluss-Konsumenten, die alle dieselbe Quelle lesen müssen (AGENTS.md). Ohne Schmelze liefert `flowWeight` das Regen-Gewicht unverändert. Über See trägt das Feld den neutralen Wert 1,0, damit `seaLevel` (verworfene Ozean-Starts) denselben Anteil verwirft wie ungewichtet und der Tropfen-Etat auf Land gleich bleibt. Leeres Array = gleichverteilte Starts (bit-identisch).

`spawnPosition` zieht per Ablehnungs-Stichprobe (von Neumann): Vorschlag gleichverteilt, angenommen mit `weight[k] / weightMax`, statt je Charge eine 700k-Zellen-Verteilungstabelle zu bauen. Zellen mit Maximalgewicht werden ohne Ziehung angenommen; dadurch ist ein konstantes Gewichtsfeld bit-identisch zum ungewichteten Fall (`testUniformRainWeightIsBitIdentical`). Ungewichtet sind es exakt zwei Ziehungen (bit-identisch zu vor #9).

Deckel `spawnRejectionTries` = 24 Neuziehungen je Tropfen, danach gilt der letzte Vorschlag; der Aufwand bleibt hart beschränkt. Annahmerate = Mittel(w)/max(w); mit dem auf das Landmittel normierten Gewicht (#10) ist Mittel(w) ≈ 1 und max(w) gemessen 1,84 … 2,91 (n=832, Seeds 1337/7/99, über 50k Jahre fallend), also 0,34 … 0,54, im Mittel 2–3 Vorschläge. Rest-Verzerrung im ungünstigsten Fall: 0,66^24 ≈ 2·10⁻⁵, gegen die 5,6-fache Gewichtsspanne vernachlässigbar.

`flowMax` wird mit einer Roh-Puffer-Schleife bestimmt statt `Array.max()`: der generische Sequence-Pfad (Iterator plus Closure je Element) tastet 692k Zellen ab; die Schleife vergleicht in derselben Reihenfolge und liefert denselben Wert.

## Zufallsstrom je Tropfen (`dropRNG`, Issue #2)

Mit `firstDrop` zieht jeder Tropfen seinen Startpunkt aus einem eigenen, aus seiner laufenden Nummer (`Terrain.dropsEmitted`) abgeleiteten Strom: Tropfen Nr. j ist derselbe Tropfen, ob er einzeln in einem Frame-Schritt fällt oder als einer von 360 in einem +10.000-Jahre-Sprung (`DtInvariance.testDropletStreamIsChunkingInvariant`). `firstDrop = nil` ist die Einmal-Charge aus einem Strom ab `seed`, wie vor #2; richtig für Chargen ohne Zeitbezug und fester Größe, also den Stream-Map-Spin-up der Generierung (`Terrain.spinUpStreamMap`), der so seine kalibrierte Realisierung behält.

Mulberry32 ist ein sequenzieller Generator und liefert aus benachbarten Startzuständen keine unabhängigen ERSTEN Ausgaben; genau die braucht der Tropfen (zwei für den Startpunkt, die dritte für den Annahme-Zug). Deshalb wird der Index vorher mit dem splitmix64-Finalizer gemischt und ein Aufwärm-Zug gemacht. Gemessen, weil zuerst falsch gemacht: mit nur `index · 2654435761` fiel die gewichtete Luv/Lee-Drainagedichte von ×1,14 auf ×1,01, die Niederschlags-Gewichtung war praktisch wirkungslos, obwohl Randverteilung (Chi² 67 gegen 63 df) und Serienkorrelation (lag-1 ~1e-3) unauffällig blieben; der Fehler steckte allein in der Kopplung von Position und Annahme-Zug. Mit Finalizer und Aufwärm-Zug ×1,21 (`RainWeightedFlow`-Wächter).

Betrifft: `Hydraulic.erode`, `Hydraulic.spawnPosition`, `Hydraulic.dropRNG`, `Hydraulic.spawnRejectionTries`, `Terrain.flowWeight`, `Terrain.dropsEmitted`, `Terrain.spinUpStreamMap`
