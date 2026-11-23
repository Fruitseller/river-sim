# Pass-Reihenfolge im Sim-Schritt und der Testpfad ohne Tropfen

Die Reihenfolge der Pässe in `Terrain.step()` folgt der LEM-Konvention und ist nicht beliebig (`docs/research-terrain-aging.md` §4; die vollständige Liste steht in `AGENTS.md`). Grob: Hebung (abklingendes U(t), Relief-Servo nur als Untergrenze) → Lithologie aus der frischen Höhe (#12) → `computeFlow` (Priority-Flood nach Barnes et al., D8, MFD) → Gletscher (`updateIce`, #35) → Mäander → `outletIncision` → Pfützen/Seen → `braidPass` → Tropfen-Erosion (`Hydraulic.erode`) und Stream-Map-EWMA → Hangdiffusion → Brandung → Klima-Vertikale → Vegetation.

Der Gletscher steht zwischen Abflussfeld und fluvialer Makro-Inzision: er braucht das frische Bett, und seine Maske `underIce` legt den fluvialen Abtrag unter dem Eis still. Seit #96 schreibt jede fluviale Bettbewegung über den einen Funnel (`erodeCell`/`depositCell` und ihre Fassungen): Mäander-Carve und -Ufer, Altarme, Braid-Fracht, Auen-Aggradation, Auslass-Inzision, Tropfen und Pinsel. Ungegatet laufen nur Hangdiffusion und Brandung (keine fluvialen Pässe, `docs/glacier-measurements.md` §I.1).

Die fluviale Makro-Inzision ist `outletIncision` (Flächen-Stream-Power, impliziter n=1-Solver in Empfänger-Reihenfolge, unbedingt stabil bei großen Zeitschritten). Die feine dendritische Textur legen die Tropfen. Gerundet wird über lineare Hangdiffusion mit räumlich variablem kappa (`hillslopeDiffusion`), nicht über Schwellen-Talus. Beide Raten moduliert das Gesteinsfeld (`lithHardness`/`lithErodeK`).

Zellen, deren Bett der Gürtel-Stempel im laufenden Schritt setzt (`inBelt`), lässt `channelCarve` aus; sonst gräbt er seine Einzell-Rinne in die Gürtelsohle.

Der Zweig ohne Tropfen (`hydraulicEnabled = false`: `transportLimited` + `diffusionPass`) ist reiner Testpfad, den die isolierten Mäander-Kopplungstests (`meanderCfg()`) bewusst nutzen: Carve, Altarm und Altern ohne Tropfen-Rauschen. `transportLimited` ist massenerhaltender Sedimenttransport (Fracht `qs` gegen Kapazität `Qc = Kt·Aᵐ·S`, stromauf nach stromab über `order` rückwärts; löste seinerzeit die rein detachment-limitierte Grid-Inzision ab, Commit „B (M3)"). Auch er bewegt das Bett nur über den Funnel und ist damit unter Eis stillgelegt; sonst hinge die Zusicherung „unter Eis kein fluvialer Abtrag" am Erosionszweig. Vergletscherte Zellen reichen ihre Fracht unverändert an den Empfänger weiter.

Betrifft: `Terrain` (Klassendoku), `Terrain.step()`, `Terrain.inBelt`, `Terrain.channelCarve`, `Terrain.transportLimited`, `Terrain.Bed`
