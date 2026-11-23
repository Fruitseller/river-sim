# Großform: ein Gebirgskamm als Skelett, vor-erodiert, mit Randabstand

Bis #174 legte die Generierung `ridged01`-Grate über die ganze Landfläche; ein Massiv-Rauschen modulierte nur die Höhe, nicht die Form. Auch das Tiefland war gratig, nur niedriger, und zerfiel in 12–24 Flecken (`docs/zielbild-measurements.md`). Seit #174 (Paket A) baut `generateRangeRelief` das Relief aus einem Skelett (`RangeSkeleton`): ein gekrümmter Kamm entlang der langen Inselachse (beim Archetyp Küste parallel zur Küste im Hinterland) mit zwei bis drei Seitenästen, dazu zwei bis vier Haupttäler vom Kammfuß zur Küste. Mit dem Abstand zum Skelett blendet das Relief von Graten über Hügel auf eine flache Küstenebene über. Jeder Seed bekommt eigene Makro-Parameter (Form, Relief, Archetyp Insel/Küste/Archipel), deterministisch über Mulberry32.

Hügelland reicht bis etwa 3,6 R (Halbbreite des Gebirges). Mit 2,4 R (erster Entwurf, gemessen) blieb zwischen Kamm und Küste eine freie Ebene als Kegel, von dem viele kleine Läufe parallel zur Küste rinnen, statt sich in den Tälern zu sammeln. Die Talsohle steigt zum Talschluss mit einem Gefälle weit unter der Mäander-Schwelle.

Ebenenhöhe 0,20 über einem Meer bei 0,15: die Küstenlinie liegt im flachen oberen Teil der Smoothstep, das Küstengefälle der Ebene (≈ 0,002 je Zelle) bleibt unter der Mäander-Schwelle (0,02 · cellSize ≈ 0,003). Daher auch `fWidth ≥ 0,30`.

Zentrum und Ausdehnung sind enger als vorher (±0,06 n und fStart 0,55–0,70 statt ±0,17 n und 0,58–0,88 mit bis zu 1,8-facher langer Halbachse): die Insel soll als Ganzes im Gitter liegen. Kein Land am Gitterrand, sonst endet die Insel in einer geraden Kante und das Heightfield zeigt seine senkrechte Unterseite; der Randabstand ist verrauscht, damit die Küste nicht parallel zum Rand läuft, und relativ zu n (bei 720: 24 Zellen Rand, 72 Zellen Rampe, ±14 Zellen Rauschen). Der Zug, der früher `mBias` lieferte, bleibt als `_ = gr.next()` stehen, damit die folgenden Züge je Seed ihre Werte behalten.

Die Tektonik (`upliftBase`) ist ridged und positiv vorgespannt: Hebung auf Graten trägt langfristig gratige Berge, ein glattes Hebungsfeld erodiert zu runden Kuppeln; die Vorspannung trägt die Landmasse, weil detachment-limited Stream-Power Material ins Meer austrägt, sonst erodiert die Insel über 100k+ Jahre zu Graten weg. Seit #174 hebt sie nur im Gebirgsgürtel (positiver Teil), sonst höbe der Relief-Servo das Tiefland über Jahrtausende wieder zu Hügeln.

Der fertig erodierte Look entsteht nicht über zehntausende Sim-Jahre, sondern einmal bei der Generierung mit dem nicht simulierten Erosionsfilter von Rune Skovbo Johansen („Fast and Gorgeous Erosion Filter", Referenz-GLSL in `docs/references/runevision-erosion/`, Portierung unter MPL-2.0, s. `NOTICE`). Jeder Punkt ist unabhängig auswertbar, also parallel und deterministisch; Droplets, Stream-Power und Mäander arbeiten danach normal weiter. Nur Land wird gefiltert, Küste und Meeresboden bleiben unberührt; `heightOffset` senkt das Feld, damit Rinnen netto carven statt Grate aufzuschütten. Die Parameterwerte stehen gegen das GLSL-Original.

Das Skelett ist reine Generierungs-Geometrie und reist nicht im Spielstand; die daraus entstehenden Felder `h` und `upliftBase` tun es.

Verworfen: Randabstand in absoluten Zellen; er fraß den Testwelten (n = 96…256) einen Großteil des Landes.

Folgen: `generateLegacyRelief` bleibt unverändert und bit-identisch erhalten, weil die Mechanik-Wächter ihre Testwelt darauf kalibriert haben (`cfg.rangeLandform = false`, `calibrationRangeLandform`).

Betrifft: `Terrain.generate`, `Terrain.generateRangeRelief`, `Terrain.generateLegacyRelief`, `Terrain.upliftBase`, `Terrain.applyUplift`, `RangeSkeleton`, `SimConfig.rangeLandform`, `ErosionFilter`, `ErosionFilter.apply`, `SimConfig.preErodeParams`, `NOTICE`
