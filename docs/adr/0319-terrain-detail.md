# Shader-Rinnen gleichen die sichtbare Alterung aus und folgen dem Abfluss

Die zusätzlichen Shader-Rinnen gleichen den sichtbaren Alterungskontrast aus, ohne die Sim-Höhen umzuschreiben: junges Gelände schwächer als der frühere konstante Wert 0.30, altes stärker, dazwischen glatt und gedeckelt. Maßgeblich ist das Alter der hochgeladenen Höhen, nicht das der Sim, denn im Zeitraffer rechnet die Sim schon am nächsten Schritt (`docs/perf-measurements.md` §L); `_upload_heights` bekommt deshalb das Jahr seiner Höhen.

Der Detail-Layer allein degenerierte auf der gealterten Welt zu einem uniformen Tapeten-Muster (Nutzer-Abnahme 2026-09-02): prozedurales Noise bindet an keine echte Geländestruktur. Seit PR #106 bündelt die Abfluss-Textur (`flow_tex`, R8 aus `WaterFieldRenderer.flowDetailField`) die Rinnen dort, wo Wasser wirklich abfließt; das Stärke-Fenster des Shaders folgt dem Kalibrier-Vertrag in `WaterRender`. Das Feld reist seit #214 nur im Frame (`flow`-Schlüssel).

Betrifft: `game/scripts/Main.gd` (`_upload_heights`), `game/shaders/terrain.gdshader` (`flow_tex`), `WaterFieldRenderer.flowDetailField`, `RenderContractTests.testTerrainDetailCounterbalancesVisualAging`, `RenderContractTests.testTerrainDetailFollowsRealDischarge`
