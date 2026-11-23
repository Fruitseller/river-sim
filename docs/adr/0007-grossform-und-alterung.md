# Großform: fertiges Gebirge am Orogenese-Höhepunkt, danach abklingende Hebung

Bis #174 legte die Generierung `ridged01`-Grate über die ganze Landfläche; auch das Tiefland war gratig und zerfiel in 12–24 Flecken (`docs/zielbild-measurements.md`). Bis #13 hielt eine konstante Hebung mit Relief-Servo die Insel im Fließgleichgewicht, und ein Gleichgewicht altert nicht.

Entscheidung: Die Generierung liefert den fertigen, scharfen Gebirgszustand am Orogenese-Höhepunkt, ohne Aufbauphase. Danach altert die Welt allein über eine abklingende Hebung und die weiterlaufende Hangdiffusion („jung spitz → alt rund").

Skelett (#174, `generateRangeRelief`): ein gekrümmter Kamm entlang der langen Inselachse (`RangeSkeleton`) mit zwei bis drei Seitenästen und zwei bis vier Haupttälern zur Küste; mit dem Abstand zum Skelett blendet das Relief von Graten über Hügel auf eine flache Küstenebene über. Hügelland reicht bis etwa 3,6 R (Halbbreite des Gebirges); mit 2,4 R blieb ein Kegel, von dem viele kleine Läufe parallel zur Küste rinnen. Ebene 0,20 über einem Meer bei 0,15: das Küstengefälle (≈ 0,002 je Zelle) bleibt unter der Mäander-Schwelle (≈ 0,003). Kein Land am Gitterrand, sonst endet die Insel in einer geraden Kante und das Heightfield zeigt seine Unterseite; der Randabstand ist verrauscht und relativ zu n. Die Tektonik `upliftBase` ist ridged und positiv vorgespannt und hebt nur im Gebirgsgürtel, sonst höbe der Relief-Servo das Tiefland wieder zu Hügeln.

Vor-Erosion: der erodierte Look entsteht nicht über zehntausende Sim-Jahre, sondern einmal bei der Generierung mit dem nicht simulierten Erosionsfilter von Rune Skovbo Johansen („Fast and Gorgeous Erosion Filter", Referenz-GLSL in `docs/references/runevision-erosion/`, Portierung unter MPL-2.0, s. `NOTICE`). Jeder Punkt ist unabhängig auswertbar, also parallel und deterministisch; nur Land wird gefiltert, `heightOffset` senkt das Feld, damit Rinnen netto carven.

Abklingende Hebung (#13): `U(t) = U_floor + (U₀ − U_floor) · e^(−t/τ)`. Nach Baldwin/Whipple/Tucker 2003 (`docs/research-terrain-aging.md` §3) altert ein stationäres Gleichgewicht mit konstantem U nie; erst wenn die Tektonik abschaltet, zerfällt das Relief. `step()` integriert U(t) über den Schritt geschlossen (`upliftDecayAmount`), Zeitraffer und Sprung tragen exakt dieselbe Hebung ein. U₀ ist der Rest der Orogenese, kein Anschub, also kein Wachstums-Puls. Gewählt U₀ = 0,0008, U_floor = 0,1·U₀ („Appalachen-Sockel"), τ = 40000 Jahre (Recherche-Band 30k–60k, 40k hält die Seen am besten). Ergebnis (n = 160, Seed 1337, 0 → 100k): relief 0,5335 → 0,3883 (−27 %), Gratkrümmung −0,0453 → −0,0219, maxH monoton fallend; derselbe Lauf mit dem alten Servo stieg auf relief 0,5097 zurück (`docs/terrain-aging-measurements.md`).

Verworfen (n = 160, Seed 1337, 100k; relief / Gratkrümmung / See-Anteil, wo gemessen):
- U₀ 0,006: die Berge wachsen (maxH 0,6836 → 0,7647, meanLand +18 %); 0,003 dreht ab 20k wieder hoch.
- U₀ 0,0015: 0,4336 / −0,0279 / 0,029, altert zu langsam, die Auslass-Inzision räumt jedes Becken frei; 0,0012 milder dasselbe.
- U₀ 0,0004: 0,3647 / −0,0212, der Sockel trägt nicht (200k: 0,3135 gegen 0,3359).
- Ohne Floor: Relief nach 200k 0,2680, unter der Einebnungs-Schwelle 0,30 von `LongRunCollapse`.
- Konstante Hebung `upliftPer100y` über das volle Tektonik-Feld: 0,009 stockte die Landmasse in 100k um +73 % auf, 0,0015 schob mittlere Grate je 10k-Klick sichtbar hoch (+0,03). Produktion 0, nur gepinnte Testkonfigs setzen sie.
- Randabstand in absoluten Zellen: fraß den Testwelten (n = 96…256) einen Großteil des Landes.

Folgen: Der Zufallszug, der früher `mBias` lieferte, bleibt als `_ = gr.next()` stehen, damit die folgenden Züge je Seed ihre Werte behalten. `generateLegacyRelief` bleibt unverändert und bit-identisch, weil die Mechanik-Wächter ihre Testwelt darauf kalibriert haben (`rangeLandform = false`, `calibrationRangeLandform`). Das Skelett reist nicht im Spielstand, `h` und `upliftBase` schon.

Betrifft: `Terrain.generate`, `Terrain.generateRangeRelief`, `Terrain.generateLegacyRelief`, `RangeSkeleton`, `Terrain.upliftBase`, `Terrain.applyUplift`, `Terrain.upliftDecayAmount`, `ErosionFilter`, `SimConfig.preErodeParams`, `SimConfig.rangeLandform`, `SimConfig.upliftDecayStartPer100y`, `SimConfig.upliftDecayFloorPer100y`, `SimConfig.upliftDecayYears`, `SimConfig.upliftPer100y`, `NOTICE`
