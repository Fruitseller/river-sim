# Vertragstest der Wasser-Geometrie

`game/tests/water_geometry.gd` prüft die Zusagen von #34 an den Renderpfad (Messprotokoll `docs/geometry-water-measurements.md`):
- Mündung geschlossen: jedes Fluss-Band, dessen Lauf binnen weniger Zellen Wasser erreicht, endet im Wasser; ein trockenes Ende ist nur erlaubt, wenn in Reichweite kein Wasser liegt (der Lauf versickert).
- Kein doppeltes Wasser: wo der Raster-See-Kanal malt (Wassersäule über `rawWet` = 0,03), ist das Fluss-Band ausgeblendet.
- Deltas: an Mündungen mit flachem Ablagerungskörper Distributär-Arme (Typ 0,5), an Steilufern nicht.
- Altarme: eigene Bänder (Typ 1,0) mit Stillwasser-Kodierung (Richtung exakt 0, `COLOR.rg == 0,5`) und Alters-Fade unter der Maximal-Deckkraft.
- Physik-Neutralität des Geometrie-Baus (Determinismus s. RenderStateTests).

Wächter gegen Messlauf: ohne Überschreibung prüft der Lauf eine feste Welt mit festen Erwartungen. Mit `RS_SEED`/`RS_STEP` ist er ein Messlauf: die Invarianten bleiben scharf, die Existenz-Zusagen entfallen, weil eine bestimmte Welt Altarme trägt oder nicht (Physik, keine Render-Eigenschaft; Seed 907 hat nach 60.000 Jahren keinen wassergefüllten Altarm mehr).

Prüfjahr: der erste Zustand ab Jahr 20.000, jedes Jahrtausend bis 80.000, der Altarm- und Delta-Bänder trägt. Bis #174 stand hier fest 30.000 J., gemessen auf der damaligen Welt (Seed 1337: 15.000 → 0, 20.000 → 0, 25.000 → 4, 30.000 → 4, 40.000 → 1 Altarm-Bänder). Mit der Großform aus #174 und der libm des Linux-Runners traf 30.000 J. eine Lücke. Jedes Jahrtausend statt jedes fünfte, weil gleichzeitig nur 0–4 junge Altarme wassergefüllt sind (Seed 1337, 20.000–80.000 in 5.000er-Schritten, macOS) und der Linux-Runner im 5.000er-Raster keinen traf.

Zusammenfluss (`WaterRender.ribbonJoin*`, Befund 2026-10-18): ein Zubringer ohne Wasser in Reichweite läuft bis in das Band seines Hauptlaufs und blendet darunter aus; sein Ende liegt im anderen Band, die Mündung prüft das Band des Hauptlaufs. Ohne die Ausnahme zählte das als Spalt (macOS, Seed 1337 Jahr 20.000: Zubringer endet bei Zelle 78,510 in einem Hauptlauf, das Meer 14 Zellen stromab). Die Prüfung `_inside_other_river` nimmt quer `hw + cs` statt `hw + halbe Zelle` wie `stampCoverage`, weil sie den exakten Endpunkt prüft, `stampCoverage` aber über Zellmitten urteilt (Versatz quer bis ~0,7 Zellen). Unsichtbare Quellenanfänge (Halbbreite 0, Alpha 0) und schwach deckende Ausläufer (< `ribbonJoinCoverage`) zählen nicht. Im Selbsttest liegt der Quellpunkt 4 Zellen vor der Naht des gedeckten Segments, außerhalb dessen Überhang; näher nähme ihn der Naht-Fußabdruck des Nachbarn an (CI-Befund zu 935bcf8), und der Fall prüfte nicht mehr den Quellenanfang.

Wasserfläche = Ozean-Ebene oder Raster-See. Die Ozean-Ebene deckt jede Zelle unter `sea` (`ocean.gdshader` verwirft nur darüber), die Kontur-Schwelle gilt nur für den Raster-See. Seit die Bänder ab der Wasserlinie ausblenden (#174), endet ein Band auf kaum überfluteten Meereszellen; mit der See-Schwelle auch fürs Meer zählte das als Spalt (Linux-Runner, Seed 1337 Jahr 20.000: Bandende auf sea − 0,0002, Schwelle erst drei Zellen weiter).

Betrifft: `game/tests/water_geometry.gd`, `WaterRender.ribbonJoin*`, `WaterRender.lakeRawWetDepth`, `RiverRibbonRenderer.stampCoverage`
