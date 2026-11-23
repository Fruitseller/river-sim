# Strömungsmuster auf Wasser: Fließkarte in Band-Koordinaten, Ausblendung unter Pixelgröße

Kräuselung, Schimmer, Strömungsstriche und Schaum auf Bändern, Raster-Wasser und Meer entstehen aus strömungs-ausgerichtetem Rauschen, nicht aus Sinus-Wellen längs der Bogenlänge (die malten gleich weite Querstreifen).

Koordinaten: auf dem Band x = Bogenlänge (UV.y, Welt, stromab stetig), y = Quer-Position in Weltmaß (UV.x × Bandbreite; bis zum Review zu #174 UV.x allein, damit war die Kräuselung auf jedem Band gleich viele Zellen breit). NICHT `dot(Weltposition, Richtung)`: die Richtung dreht je Stützpunkt (im Raster-Wasser springt sie je D8-Zelle), und mit der ~50 Einheiten langen Position multipliziert sprang die Phase von Quad zu Quad (Querschraffur, Höhenlinien-Moiré, Ringe und Zellblöcke auf Seen, Befund #174). Stillwasser hat keine Richtung und kräuselt nur schwach.

Fließkarte in zwei versetzten Phasen (Valve 2010): das Tempo wechselt entlang des Laufs (Gefälle, Riffel), eine stetige Verschiebung würde das Muster zerren. Jede Phase verschiebt höchstens eine Periode bzw. Rauschzelle und springt zurück, wenn ihr Gewicht null ist. Der Schimmer nutzt dieselbe Fließkarte.

Ausblendung: jede Rausch-Oktave blendet aus, sobald ihre Zellen unter die Pixelgröße fallen; die Ferne bleibt ruhig statt in Moiré und Streifen zu zerfallen. Fenster und Oktaven-Folge teilen Band und Meer. Der Footprint wird vor jedem nicht-uniformen discard bestimmt (s. [ADR 0174](0174-ableitungen-und-numerik.md)). Oktaven-Versätze, Hash-Konstanten und Differenzen-Schritte sind numerisch, keine Kalibrierung; Frequenzen und Amplituden sind Optik-Zahlen des jeweiligen Shaders (das Raster-Wasser kräuselt mit 0,015…0,05).

Schaum (Gremium, Befund 3): Weißwasser nur, wo die Lauf-Größen es sagen (Stufen, Engstellen, Zusammenflüsse, Riffel), weich über ein breites Fenster auf Streifen UND einem runden Rauschen. Die frühere Schwelle (0,05 breit auf dem längs gestreckten Wertrauschen, dazu Schaum an jedem Außenbogen) schnitt dessen Zellen als weiße Rechtecke aus („Fahrbahnmarkierungen“). Im Raster-Wasser Schaum nur an Gefällestufen, nicht als Saum an jeder Uferlinie.

Sonnenglitzern: Facetten in Bildpunktgröße, in der Totalen das stärkste Wassersignal. Zellgröße in Zweierpotenzen der Pixelgröße (sonst sprang die Zellgrenze je Bildpunkt), je Zelle nur ein runder Punkt an zufälliger Stelle; vorher leuchtete die ganze Zelle als blockiges Quadrat (Gremium, Befund 3).

Betrifft: `game/shaders/water.gdshader` (`ribbon_ripple_grad`, Fließkarte, Schaum, Glitzern), `game/shaders/terrain.gdshader` (Wasser-Block), `game/shaders/ocean.gdshader` (`ocean_wave_grad`)
