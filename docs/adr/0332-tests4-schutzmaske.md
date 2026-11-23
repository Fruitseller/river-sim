# Schutzmaske: Inhalt und Prüfweise

Die Schutzmaske (`WaterProtectMask`, Issue #154) sperrt Kronendach und Render-Verschiebung an Wasser: sichtbare Raster-Flüsse und Seen aus dem Wasserfeld, jede gebaute Bandfläche (`RiverRibbonRenderer.bandCoverage`, auch wo der Raster-Deckel das Wasser darunter entfernt hat), die nasse Wiese (#174 C), frische Bänke (#174 C2) ohne Saum, und einen Saum von `WaterRender.protectSeamCells` Zellen (Chebyshev) um alles übrige. Trockenes Land außerhalb bleibt frei, das Render-Wasserfeld ändert sich nicht, gleiche Welt ergibt dieselbe Maske, Pinsel, Neugenerieren und Laden hinterlassen keine veraltete.

Seen unter `WaterRender.wetMeadowMaxCells` (200 Zellen) malt der Frame als nasse Wiese, deshalb hat der See-Test Radius 9. Der alte Test sah kleinere Seen nur, weil er das Wasserfeld ohne vorherigen Band-Bau zog: ohne Mesh gilt in `WaterFieldRenderer.bytes` jeder Kanal als „hat ein Band", und der Korridor-Stempel zählte den Tümpel als banded. Durch den Frame baut der Band-Bau zuerst und meldet ehrlich „kein Kanal mit Band".

Nach einem Pinselstrich wird bewusst nicht gegen einen frischen Render-Zustand verglichen: der Frame deckelt den Band-Neubau an der Zentrumslinien-Bewegung (#93/#94), ein Strich bewegt die Linien nicht, der gebrauchte Zustand behält seine Bänder legitim, während ein frischer sie baut. Verglichen wird gegen die Neuberechnung aus den eigenen Frame-Eingaben; ein stehengebliebener Cache (der Fall aus #93) wiche davon ab.

Betrifft: `WaterProtectMask`, `RenderState.frame`, `WaterFieldRenderer.bytes`, `WaterRender.protectSeamCells`, `WaterRender.wetMeadowMaxCells`, `WaterProtectMaskTests`
