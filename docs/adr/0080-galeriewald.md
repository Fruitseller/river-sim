# Galeriewald und Ufersaum des Kronendachs

Entlang von Flussbändern und Seen steht ein lückiger Galeriewald, auch wo die Vegetation sonst Wiese trägt (Look-Iteration 12, Hill-Climber Problem 1). Der Grundwald hält weiter die volle Schutzmaske ein; für den Galeriewald gelten eigene, gemessene Sperren, weil die allgemeinen Gates am Ufer zu viel wegnehmen.

## Abstand zum Wasser (`waterSeamCells` = 1)

Die Schutzmaske (`WaterRender.protectSeamCells` 2) bleibt für die Render-Verschiebung. Für das Kronendach reicht eine Zelle Chebyshev-Abstand, genau der Filterabstand der linear gelesenen Textur (Wächter `testNoForestOverRiversLakesOrBands`). Mit zwei Zellen plus Lichtungs-Rauschen lag jeder Lauf in einem kahlen Korridor, der sich in der Totalen als Straße las; in den Referenzbildern steht Gehölz bis ans Ufer. An Bändern zählt als Wasser die äußerste Lage der verrauschten Wasserlinie (`RiverRibbonRenderer.bandVisibleCoverage`), damit die Maske genau an der gemalten Wasserfläche auf null ausläuft. Bis Review Neon Nr. 1 zog der Bandkern davon noch eine Zelle ab und ließ das Rauschen weg; die interpolierte Maske reichte damit in 2 % der sichtbaren Wasserpunkte hinein (Testwelt n = 192, bis 0,79).

## Breite und Lücken

Breite in Zellen ab dem Wasser schwankt mit dem Auwald-Rauschen zwischen `riparianWidthLo` und `riparianWidthHi`; wo das Rauschen unter `riparianGapLo … Hi` fällt, reißt das Band ab. Weiter als `riparianReachCells` misst die Abstandskarte nicht. Auwald-Rauschen: 0,8/Welteinheit (≈ 125 m, 8 Zellen), Mittel ≈ 0,47.

- Ursprünglich 5–14 Zellen (Zelle ≈ 16 m: 80–220 m; schmaler blieb der von der Sim gerodete Mäandergürtel als blasser Streifen neben dem Gehölzband stehen), Lücken ab 0,22/0,30, Reichweite 16.
- Look-Iteration 13: 3–7 Zellen, Reichweite 8, Lücken ab 0,30/0,38. Das breite, fast geschlossene Band fraß in `diorama` und `tal` Lichtungen und Grasrücken auf (Bewerter Nr. 12: „Baumkugeln gleichmäßig über nahezu alle Hänge"). Mit 2–6 und 0,38/0,46 (rund die Hälfte des Ufers frei) urteilte der Bewerter fast nur GLEICH zu keep4 (A 1 B 5 GLEICH 9), mit 3–7 A 2 B 8 GLEICH 5.
- Look-Iteration 14: 2,5–5 Zellen, Reichweite 6, Lücken ab 0,34/0,42, und nur noch an Bändern und Seen (`WaterProtectMask.canopyGuard`); in `tal` war die Talmitte gegen keep4 zugewachsen.

## Dichte (`riparianDensity` = 1,5)

Über 1, damit die Maske im Kern des Bands auch bei voller Breite und weichem Rauschen sättigt. Der Shader setzt eine Krone erst ab `crownMid` plus bis zu `crownSpread` × 1,5 (lichte Bestände ~0,95); mit 1,0 lag die Maske am Ufer bei 0,6–0,9 und zeigte Wiese statt Kronen (Debug-Aufnahme, Seed 1337, Jahr 20.000).

## Sperren am Ufer

Gemessen jeweils auf Produktion, Seed 1337, an Zellen 2–5 vom Wasser ohne Wald:

- Fels (`riparianRockLo/Hi`, G-Kanal von `surfaces`): 0,15/0,40 sperrte ein Drittel, meist Schotter im Talboden; 0,30/0,60 noch ein Fünftel; 0,45/0,75 lässt Wände und Schutt frei, nicht aber den Talboden.
- Meer (`riparianShoreLo/Hi`, Höhe über Meer in Sim-Einheiten), flacher als `shoreLo/Hi`, weil Mündungsebenen kaum über dem Meer liegen: 0,002/0,010 nahm ein Viertel der ufernahen Zellen ohne Wald heraus, 0,0005/0,003 noch ein Zehntel. Den Strand sperrt das Sandgewicht.
- Sand (`riparianSandLo/Hi` 0,15/0,30, A-Kanal der Makrofarbe): dieselbe Schwelle wie die Bank-Sperre (`WaterRender.barProtectSand` 0,25), darunter liegt nur der auslaufende Rand einer Bank. 0,05/0,20 sperrte ein Fünftel.
- Wand (`riparianWallSlopeLo/Hi` 2,4/3,2 ≈ 67°/73°, Weltsteigung): `Terrain.macroSlope` mittelt über ±2 Zellen und schließt am Ufer das eingetiefte Gerinne ein; mit dem allgemeinen Wand-Gate fiel knapp die Hälfte der Zellen 2–3 vom Wasser (Jahr 23.000) darunter. So tragen Uferböschungen Gehölz, echte Wände bleiben frei.

## Nachwachsen (`riparianRegrowYears` = 150)

Innerhalb der Galeriewald-Reichweite (`riparianWidthHi` + 1 Zellen) wächst der Wald über 150 statt `regrowYears` Jahre nach (Weichholzaue: Weiden und Erlen besiedeln verlassenes Gleithang-Land in Jahrzehnten). Mit 800 J. lag hinter jedem wandernden Bogen ein kahler Streifen; im ersten Frame stand der Galeriewald, im Zeitraffer nach 20.000 J. nicht. Der Rest des Landes behält `regrowYears` (Unruhe-Ziel aus #167).

Betrifft: `CanopyRender.waterSeamCells`, `CanopyRender.riparian*`, `WaterProtectMask.canopyGuard`, `RiverRibbonRenderer.bandVisibleCoverage`, `SimRender.ForestCanopyMask`
