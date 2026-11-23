# Begründete Stellen im Ablauf von step()

Die Reihenfolge in `step()` folgt der LEM-Konvention (FastScape, `docs/research-terrain-aging.md` §4): Hebung → Abfluss → Stream-Power/Auslass (Makro-Täler) → Droplet (Textur) → Hangdiffusion (Grate runden) → Wellen. Die vollständige Liste steht in AGENTS.md; hier die Begründungen der einzelnen Stellen.

- Hebung zuerst, mit Servo als Untergrenze unter dem Integral (s. ADR zur Hebung).
- `regenerateDisturbed` (Issue #26) vor `computeFlow`: das Mikro-Relief ist eingetragen und Mäander-/Altarmzustand abgeräumt, bevor die Entwässerung dieses Schritts läuft; ohne Störung ein reiner Boolean-Test.
- `updateLithology` (Issue #12) vor jedem Erosionspass: die freigelegte Schicht folgt aus `h`, und `h` hat sich gerade durch die Hebung verschoben. Reine Ableitung ohne Zustand, deshalb nur "vor der Erosion" kritisch.
- MFD: Braiding ist MFD-Physik, nicht nur Rendering; das Feld darf nie hinter dem Terrain zurückbleiben. In der Produktion steht `mfdUpdateInterval` auf 1, der Takt-Zweig ist damit wirkungslos; nachgemessen für Issue #43 ist `computeMFDArea` NICHT über den Takt einsparbar (`docs/perf-measurements.md` §E).
- Gletscher (Issue #35) NACH dem Abflussfeld, weil das Eis auf dem Bett fließt, das der frische Priority-Flood gesehen hat, und VOR jeder fluvialen Höhenänderung, weil `underIce` über den Bett-Funnel jede fluviale Bett-Bewegung gatet (seit #96 auch Auslass-Inzision, Tropfen und Pinsel), auch den direkt folgenden Mäander-Stempel. Ohne Eis ein reiner Suchlauf.
- Fluviale Makro-Inzision zuerst im fluvialen Block: sie schneidet das kohärente Talnetz und entwässert die Becken zum Meer, an dem die Hänge dann hängen. Delta (Issue #174): der Abtrag von Inzision und Bett-Carve wird als Höhensumme davor und danach gemessen.
- Delta-Schüttung vor Hangdiffusion und Wellen, die die frische Front im selben Schritt überarbeiten.
- Klima-Vertikale (Issue #33) am Schrittende: die Temperatur liest die finalen Höhen, und die Schneebilanz muss vor `updateVegetation` stehen, wo `updateHeightBands` die Schneegrenze aus dem frischen Feld ableitet.

Betrifft: `Terrain.step`, `Terrain.computeFlow`, `SimConfig.mfdUpdateInterval`, `docs/research-terrain-aging.md`, `docs/perf-measurements.md`
