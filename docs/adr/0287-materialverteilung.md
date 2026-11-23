# Materialverteilung: WO auf der CPU, WIE im Shader, Gewichte summieren höchstens 1

WO Fels, Schutthalde, Gletschereis, Rohboden und Talboden-Wiese liegen, rechnet `SimRender.TerrainColorRenderer` auf der CPU und ist ausführbar geprüft (#174, Paket D); WIE es aussieht, rechnet der Terrain-Shader, davon ist headless nur die Struktur des Uniform-Wegs prüfbar (Muster `CanopyTests`). Die Gewichte (Vegetation, Fels, Kälte, Halde, Rohboden) summieren sich je Zelle auf höchstens 1 bis auf die Byte-Rundung, weil der Shader sie als Gewichtssumme mischt und der Rest Grund ist. Regeln: Fels auf steilen, konvexen Formen, Halden in Hohlformen unter Fels im Schüttwinkel, blankes Eis nur im Zehrgebiet (darüber Firn, liest sich als Schnee), Rohboden nur nach Pinsel-Störung, Talboden-Wiese nur auf flachem Tiefland.

Die Kältedeckung (B-Kanal von `surfaces`) bleibt bei blankem Eis und Firn voll: Wald und Kronendach sehen Schnee und Eis gleich.

Nasse Wiese (`WetMeadow.apply`): die Vegetation geht auf `wetMeadowVegetation`, die übrigen Gewichte (Fels, Halde, Rohboden, Sand) teilen sich PROPORTIONAL, was neben Kälte und Vegetation bleibt. Vorher blieben Halde, Rohboden und Sand stehen, die Summe stieg bis ~1,85 (Review zu #174 C).

Bewuchs-Deckel und Mineral-Tönung standen als Literale im Renderer, der Deckel doppelt (Review zu #174); sie liegen im Vertrag `MaterialRender`, der Renderer liest sie dort.

Shader (#237): Fels, Schutt, Kies und Sand kommen aus gescannten Materialien (Textur-Arrays, triplanar auf Wänden), nicht mehr aus der Rausch-Klüftung von #174 D, deren senkrechte Runsen in Fallrichtung der Befund „senkrechte Streifen" waren. Gepinnt ist, dass der Terrain-Shader das Include bindet, Fels und Schutt triplanar abfragt und die Scan-Normale übernimmt; das Bild prüft der Mensch. Die Include-Zeile wird als roher Dateitext geprüft, weil Präprozessor-Zeilen nicht in der Code-Sicht der `SourceProbe` stehen.

Zwei Fallen aus dem Review zu #174, die Fels, Schutt, Spalten und Kräuselung still glätteten bzw. undefiniert machten: Das Wertrauschen hasht über `vhash`, das den Zellindex zuerst auf [0, 17) faltet. Über `ehash` (Float-Produkt x·y·(x+y) auf dem rohen Index) erstarrte es ab einigen Dutzend Zellen vom Ursprung: Schutt-Körnung bei `material_pos / 0.05` auf großen Teilen der Karte konstant, Spalten und Riffel als Gitter. Ein Ganzzahl-Hash wäre ebenso genau, kostete aber gemessen +2,5 ms je Bild. Ableitungen nur im gleichförmigen Kontrollfluss: `fwidth` steht genau zweimal oben in `fragment()`; Klüftung, Körnung, Spalten und Kronen laufen hinter Verzweigungen je Pixel und bekommen die Pixelgröße übergeben.

Wolkenkörper und Wolkenschatten teilen eine Rauschquelle (#174 D): der Körper-Shader bindet das gemeinsame Include und rechnet seine Deckung mit derselben Funktion wie der Schatten; alle drei Schatten-Shader übergeben Weltposition samt Höhe (Projektion entlang der Sonne).

Betrifft: `SimRender.TerrainColorRenderer`, `SimCore.MaterialRender`, `WetMeadow.apply`, `game/shaders/terrain.gdshader`, `game/shaders/scan_material.gdshaderinc`, `game/shaders/clouds.gdshaderinc`, `MaterialTests`
