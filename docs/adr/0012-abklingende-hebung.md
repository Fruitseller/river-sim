# Abklingende Hebung ab dem Orogenese-Höhepunkt als Alterungs-Mechanismus (Issue #13)

    U(t) = U_floor + (U₀ − U_floor) · e^(−t/τ)

Baldwin/Whipple/Tucker 2003 (über `docs/research-terrain-aging.md` §3): ein stationäres Gleichgewicht mit konstantem U altert nie. Erst wenn die Tektonik abschaltet, zerfällt das Relief, während die weiterlaufende lineare Hangdiffusion die Grate rundet („jung spitz → alt rund“). `step()` integriert U(t) über den Zeitschritt geschlossen (`Terrain.upliftDecayAmount`), Zeitraffer und +10.000-Jahre-Sprung tragen exakt dieselbe Hebung ein.

Entscheidung: Start am Orogenese-Höhepunkt. Die Generierung liefert den fertigen, scharfen Gebirgszustand (ridged Multifraktal + Pre-Erosion), es gibt keine Aufbauphase; U₀ ist der Rest der Orogenese, kein Anschub, also per Konstruktion kein Wachstums-Puls. Gegenproben (n = 160, Seed 1337, 100k): U₀ = 0,006 → maxH 0,6836 → 0,7647 (Peak 0,7805), meanLand +18 %, die Berge wachsen. U₀ = 0,003 → maxH endet mit 0,6739 unter dem Start, dreht ab 20k aber wieder hoch (0,6484 → 0,6831).

U₀ = 0,0008, gut die Hälfte des alten Servo-Deckels (0,0015), klein genug, dass die Erosion ab dem ersten Schritt überwiegt; maxH über alle 5 Seeds monoton fallend. Verworfen (n = 160, Seed 1337, Servo aus, relief/ridgeCurv bei 100k; ridgeCurv = `Terrain.ridgeCurvature()`, negativ = spitz):
- 0,0015 → 0,4336 / −0,0279, See-Anteil 0,029 (200k: 0,002): altert zu langsam, und die Auslass-Inzision räumt bei dem Gefälle jedes Becken frei, die diskreten Seen verschwinden.
- 0,0012 → 0,4181 / −0,0253, See-Anteil 0,033: dasselbe milder.
- 0,0004 → 0,3647 / −0,0212, aber der Sockel trägt nicht (200k: 0,3135 gegen 0,3359 bei 0,0008).
Gewählt 0,0008 → 0,3883 / −0,0219, See-Anteil 0,052.

U_floor = 0,1·U₀ (Recherche-Empfehlung 0,05–0,1·U₀) hält den „Appalachen-Sockel“. Ohne Floor fällt das Relief über 200k auf 0,2680, unter die Einebnungs-Schwelle 0,30 von LongRunCollapse; mit Floor 0,3359 (+25 %). Im 100k-Fenster ist der Unterschied klein (0,3509 gegen 0,3883).

τ = 40000 Jahre, Mitte des Recherche-Bands 30k–60k; bei 100k (2,5 τ) ist U auf 8 % von U₀ abgefallen. Bei 100k (relief / curv / See-Anteil): τ = 30k → 0,3817 / −0,0215 / 0,032 · 40k → 0,3883 / −0,0219 / 0,052 · 60k (Floor 0) → 0,3994 / −0,0238 / 0,036. Die Alterung ist über das Band robust, 40k hält die Seen am besten.

Alterungsverlauf (Produktionspfad, n = 160, Seed 1337, alle 20k; Belege `docs/terrain-aging-measurements.md`):

    relief     0.5335 0.4706 0.4252 0.4138 0.4016 0.3883  (0 … 100k, −27 %)
    ridgeCurv −0.0453 −0.0290 −0.0253 −0.0225 −0.0226 −0.0219  (−52 % Betrag)
    maxH       0.6836 0.6206 0.5752 0.5639 0.5516 0.5383  (monoton)

Derselbe Lauf mit dem alten Servo: relief 0,5335 → 0,4569 (30k) → 0,5097 (100k), ridgeCurv ab 10k flach bei ≈ −0,030. Multi-Seed (1337/7/99/2024/555, 100k): maxH-Spitze ist bei jedem Seed der Startwert, relief fällt bei jedem; die Gratkrümmung rundet bei 4 von 5 Seeds (z. B. −0,0306 → −0,0169). Seed 7 startet als weiches Rollhügel-Terrain (curv0 −0,0173) und wird erst zerschnitten (−0,0253): die Kennzahl misst Rundung relativ zum Start. Der Wächter `TerrainAging` misst deshalb auf Seed 1337.

Alte konstante Hebung `upliftPer100y` über das VOLLE Tektonik-Feld (inkl. negativer Täler): Produktion 0 und bleibt 0, nur Testkonfigs mit gepinnter Alt-Kalibrierung (`meanderCfg`) setzen sie. Historie 0,009 → 0,0015 → 0,0: 0,009 stockte die Landmasse in 100k um +73 % auf (meanLand 0,39 → 0,68, sichtbares „Wachsen“); 0,0015 hielt die Masse etwa flach (0,39 → 0,42, Relief 0,76 → 0,65), schob mittlere Grate pro 10k-Klick aber noch sichtbar hoch (+0,03), obwohl der globale Gipfel erodierte. Ohne Dauer-Tektonik wachsen Berge nirgends, wie real ohne aktive Plattengrenze; Hebung nur noch über Sculpting/Events und die abklingende Hebung.

Betrifft: `SimConfig.upliftDecayStartPer100y`, `SimConfig.upliftDecayFloorPer100y`, `SimConfig.upliftDecayYears`, `SimConfig.upliftPer100y`, `Terrain.upliftDecayAmount`, `Terrain.applyUplift`
