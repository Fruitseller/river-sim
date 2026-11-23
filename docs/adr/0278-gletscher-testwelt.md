# Gletscher-Wächter: Testwelt n = 384 und Abnahmekriterien von #35

Die Gletscher-Suite (`Glacier`) prüft den Gletscher-Pass aus Issue #35: Eisfluss, glaziale Erosion, Moränen und die Stilllegung der fluvialen Abtragspfade unter dem Eis (`Terrain.updateIce`, Kalibrier-Logbuch bei `SimConfig.iceEnabled` ff., Modellwahl `docs/research-climate-cryosphere.md` §4/§5). Ihre Arbeitsauflösung ist n = 384, und kleiner geht es nicht.

Grund: Gletscher hängen an der Gipfelhöhe. Eis entsteht nur über der Firn-Grenze der alten Großform (h = 0.5731), und die Gipfel erodieren bei kleinem n schneller weg: bei n = 192 liegt `maxH` nach 40k Jahren bei 0.585, bei n = 640 noch bei 0.624 (`docs/glacier-measurements.md` §A). n = 384 hält den Abstand zur Firn-Grenze über 50k Jahre und ist noch schnell genug für Pflicht-Wächter.

Abnahmekriterien von #35 und ihre Wächter:
1. Zungen fließen talwärts: `testTongueReachesBelowTheFirnLine`.
2. V→U-Kennzahl entwickelt sich: `testGlaciatedValleysWidenTowardsU`, Messreihe `testValleyShapeSeriesDiagnostic`.
3. Moränen entstehen, Schichtbuchhaltung bleibt grün: `testMoraineBuildsAtTheTongue`, `testLayersStayConsistent`.
4. Unter Eis kein fluvialer Abtrag: `testNoFluvialErosionUnderIce` (isoliert), `testNoFluvialErosionUnderIceInProduction` (mit Mäander und Braiding), `testNoFluvialErosionUnderIceOnTheGridPath` (Nicht-Droplet-Zweig); Gegenrichtung `testThinIceNeitherFlowsNorGrinds`.
5. dt-invariant und deterministisch: `testIceIsFramerateIndependent`, `testThickIceTransportIsStableForLargeSteps`, `testIceIsDeterministic`.
6. Abgeschaltet bit-identisch: `testDisabledIceIsBitIdentical`, `testIcelessWorldIsBitIdentical`.

Betrifft: `Glacier.cfg`, `SimCore/Tests/SimCoreTests/Glacier.swift`
