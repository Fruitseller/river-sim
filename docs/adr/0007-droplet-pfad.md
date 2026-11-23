# Droplet-Pfad: Stream-Map, Auslass-Inzision und räumlich variable Hangdiffusion

Stream-Map (nickmcd): `streamRefRate` 0,0025 ist die Sättigung, ab der eine reife-gewichtete Tropfen-Besuchsrate (Besuche/Jahr, EWMA) als etablierter Lauf gilt (Map ≈ 0,63 bei r0, → 1 darüber). Gemessene Trunk-Raten ~0,003–0,007/J., Zufallspfade ≪ 0,001. Gedächtnis `streamMapMemoryYears` 6000: bei +2k Jahren bleibt das etablierte Netz verwandt (Jaccard 0,28 statt 0,20 bei τ = 3000), ohne Kurzfrist-Flackern.

Auslass-Inzision (`outletIncision`): Flächen-Stream-Power auf dem Entwässerungsnetz carvt Täler und Auslässe, Becken entwässern zum Meer; Ergebnis sind dendritische Rinnen und diskrete Seen (nickmcd-Look) statt einer blassen Flach-Ebene. `outletErode` 3e-5 gibt feine Rinnen über die ganze Oberfläche ohne Überkämmen; 6e-5 überkarvt bei 100k.

Hangdiffusion `hillDiffusion` 0,012 (Bodenkriechen, D·∇²z) ist RÄUMLICH VARIABEL (`hillslopeDiffusion`): sie rundet soil-mantled, sanfte Hänge und lässt hohen steilen Kahlfels scharf → gerundete Landschaft mit einzelnen spitzen Gipfeln. Das ist der fehlende Alterungs-Prozess laut LEM-Recherche (`docs/research-terrain-aging.md`). Auf n = 640 kalibriert, in `step()` auflösungs-skaliert.

Hangprozesse laufen über LINEARE Diffusion (im Nicht-Droplet-Testpfad `diffusionPass`). Die Schwellen-Talus-Variante (`thermalPass` mit talus/thermalRelax/rockCrumble) ist entfernt: sie erzeugte planare Facetten statt konvexer Kuppen und war seit dem Wechsel auf lineare Diffusion nicht mehr aufgerufen (ROADMAP „Toter Code“). Küsten-Talus (`waveTalus`, `wavePass`) ist davon unberührt.

Betrifft: `SimConfig.streamRefRate`, `SimConfig.streamMapMemoryYears`, `SimConfig.outletIncision`, `SimConfig.outletErode`, `SimConfig.hillDiffusion`, `Terrain.hillslopeDiffusion`
