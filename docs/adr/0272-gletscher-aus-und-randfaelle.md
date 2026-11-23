# Gletscher abgeschaltet, Randfälle und Langzeit-Deckel

Abgeschaltet: mit `iceEnabled = false` gibt es kein Eis und keine Maske, damit fällt das Gate des Bett-Funnels (`Terrain.Bed.erode`, seit #96 die eine Prüfstelle aller Schreiber) samt Pass weg. Der Wächter prüft die Vorbedingung dieser Bit-Identität: `underIce` bleibt leer. Der harte Aus-Wächter ist eine Welt, die nie Eis bekommt (`climateSeaLevelTemp = 40`, 0-°C-Isotherme weit über dem Gipfel): mit und ohne Gletscher-Pass bit-identisch, das prüft den Schnell-Ausstieg des Passes an seiner Kante.

`dt = 0` (Sculpt-Pfad) darf die Eisbilanz nicht um ein ULP verschieben, dieselbe Zusicherung wie bei der Schneedecke.

Färbung: Eis hat EINE Quelle, wie `snowCoverage`. `SimRender.TerrainColorRenderer` ruft `Terrain.iceCoverage` über den rohen Puffer auf, statt die Formel zu kopieren. Ohne Klima ist die Eis-Deckung exakt 0.

Zellgröße 0: ohne den `cs > 0`-Guard in `iceFlowSubStep` wurde das Gefälle `w / cs` unendlich, mit ihm die Schliff-Rate, und das Bett fiel um den vollen Teilschritt-Deckel. Geprüft auf n = 3 mit `world = 0` gegen einen Arm mit `iceErodeK = 0`; ein 1×1-Gitter erreicht den Pfad nicht (am gespiegelten Rand ist das Gefälle 0 und die Zelle eine Mulde). `iceEro` ist privat, geprüft wird seine einzige Wirkung, das Bett. Überall Frost, damit keine Moräne das Bett anfasst.

Langzeit (200k Jahre): der Deckel für das Eis ist die Konstruktion selbst (`iceFirnPerSnowYear · snow · iceTurnoverYears`, snow ≤ 1). Diese Grenze ist so weit weg, dass sie ein Entgleisen erst merkt, wenn das Eis das Relief überragt; deshalb zusätzlich eine empirische Schranke. Gemessen bleibt das Maximum unter 0.3 (`docs/glacier-measurements.md` §B); die Schranke im Code steht bei 2.0 (der Kommentar nannte 1.0, das ist veraltet). Dazu Relief < 1.0 und Schichtbuchhaltung bis 1e-9.

Betrifft: `testDisabledIceIsBitIdentical`, `testIcelessWorldIsBitIdentical`, `testZeroStepLeavesIceUntouched`, `testIceCoverIsTheSingleSourceForColouring`, `testIceWithoutCellSpacingDoesNotGrind`, `testLongRunIceStaysBounded`, `Terrain.iceCoverage`
