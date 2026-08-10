# river-sim — Stand, Roadmap & offene Punkte

Kern ist eine **Simulation** (Zeit vergeht → Erosion/Tektonik/Sediment formen die Welt),
kein Generator. Architektur und Grundentscheidungen: `PLAN.md`.

Ziel-Look: https://nickmcd.me/2020/04/15/procedural-hydrology/ — feine dendritische
Erosions-Rinnen, grauer Fels, moosgrüne Täler, weiße Gipfel, dezentes teal-Wasser.
Der Verhaltens-Abgleich mit dieser Referenz steht in
`docs/nickmcd-behavior-verification.md`.

## Aktueller Stand (Kurzfassung)

- **Erosion/Terrain:** Droplet-Hydraulik (`Hydraulic.swift`, Lague/nickmcd) legt die
  feine Textur, Flächen-Stream-Power (`outletIncision`) trägt die Makro-Täler, lineare
  Hangdiffusion (`hillslopeDiffusion`) rundet die Grate. Prozess-Reihenfolge LEM-konform:
  Uplift → Flow → SPL/Auslass → Braiding → Droplet → Diffusion → Wave.
  Pre-Erosion + Shader-Detail-Layer nach runevision (`ErosionFilter.swift`).
- **Alterung statt Regler:** die Tektonik ist eine **abklingende Hebung**
  `U(t) = U_floor + (U₀−U_floor)·e^(−t/τ)` (post-orogener Zerfall) — zusammen mit
  der linearen Hangdiffusion ergibt das „jung spitz → alt rund" statt eines ewig
  jungen Gleichgewichts. `isoHighClamp` verhindert, dass die Rest-Hebung die
  höchsten Grate erneut anhebt. Der **Relief-Servo** ist nur noch Untergrenze
  gegen echtes Einebnen (`reliefTarget = 0.05`, springt im 200k-Fenster nie an);
  sein Regelsignal ist `landReliefRobust()` (95. Perzentil − Median der
  Landhöhen), nicht `landRelief()` = max − min: letzteres hing an einer einzigen
  Extremzelle (Nadelgipfel/Sculpt-Strich steuerte die Hebung der ganzen Insel).
  Alterungs-Kennzahl ist `ridgeCurvature()` (∇²z auf Gratzellen).
- **Hydrologie:** Priority-Flood + D8 für Erosion, MFD (Freeman/Quinn) für Render und
  Braiding, EWMA-geglättete Stream-Map, Pool-Kopplung (Descend→Flood→Drain),
  Becken-Breach bei der Generierung (Becken entwässern zum Meer).
  **Becken-Wasserhaushalt (Issue #11):** ein geschlossenes Becken läuft nicht mehr
  zwangsläufig bis zur Sill voll — Zufluss (der niederschlagsgewichtete Abfluss
  aus #9/#10) gegen Verdunstung über der Seefläche deckelt den Spiegel
  (`capEndorheicBasins`, κ = `endorheicEvapRatio` = Verhältnis
  Einzugsgebiet:Seefläche). Verdunstungs-limitierte Becken sind TERMINAL (kein
  Sill-Abfluss, keine Auslass-Inzision), ihr trockengefallener Boden salzt ein
  (`saltCrust` → helle Playa im Rendering).
- **Flüsse:** Mäander als persistente Lagrange-Zentrumslinie (`Meander.swift`, Migration
  ∝ Krümmung × Abfluss, Cutoff → Altarm, Sinuositäts-Deckel), Braiding nach
  Murray & Paola (`braidPass`), Wasser-Optik im Shader (eigene Wasser-Normale,
  Fresnel, Tiefenfarbe, distanz-gefadet).
- **Karte:** n = 832 bei worldSize 130 (cellSize ≈ 0.156 — Auflösung und Weltgröße
  immer ZUSAMMEN ändern, sonst brechen alle per-Zell-Kalibrierungen).
- **Vegetation:** `veg` (Dichte 0..1, τ=250a) + Klassen `vegClass` (kahl/Gras/Wald/
  Auwald, aus veg + Flussnähe + Makro-Steigung; Flussnähe aus dem D8-Netz `area`,
  nicht aus `areaMFD` — die Klassen gehen über `vegDamp` in die Erosion).
  Gehölz (Wald wie Auwald) sitzt am UFER, nicht im BETT: die Wasserlauf-Zellen
  selbst bleiben Gras (sonst panzert die Wurzel-Kohäsion den Talboden —
  s. Braiding unten).
  Klassen gewichten die 0.6-Erosions-
  Dämpfung (Gras 1.0 = Alt-Verhalten, Wald 1.1, Auwald 1.3), Auwald bremst die
  Mäander-Migration (`meanderCohesion`). Störung: Flood-Kill (τ_kill=20a) +
  Ufer-Kill (Mäander-Bett → veg=0); Regrünung per Sukzessions-Samen-Druck
  (Dispersal-Radius 2, nur bewohnbare Standorte). Rendering: 3D-Bäume als
  MultiMesh (`treeInstanceBuffer`, deterministischer Hash-Jitter, ~26k Instanzen,
  Rebuild nur bei Max-Δveg > 0.1).
- **Spieler-Eingriffe als Störung (Issue #26):** ein Pinselstrich setzt auf den
  betroffenen Zellen einen abklingenden **Störungsgrad** (`Terrain.disturb`,
  τ = 1200 J.). Damit fällt der Zustand weg, der an der ALTEN Topografie hing
  (Vegetation, Stream-Map-EWMA, Mäanderlinien/Altarme — die Baum-Instanzen
  folgen `veg`), das Vegetations-Ziel bleibt über das Fenster gedrückt
  (Sukzession statt Sofort-Wald), die Pfützen-Verlandung ist ausgesetzt, und ein
  **Regenerations-Budget** (`regenPending`) trägt Setzung/Rebound des bewegten
  Materials (35 %, differentielle Kompaktion → die begrabene Struktur schlägt
  gedämpft durch) plus ein kleines fBm-Mikro-Relief über das Fenster ein.
  Der SOFORT-Effekt des Werkzeugs bleibt exakt (die flache Fläche ist flach);
  ohne Eingriff läuft alles bit-identisch wie vorher. Diagnose zeigt seitdem
  Hochseitenrelief (p95−Median) UND Talseitenrelief (Median−p05) getrennt.
  Messreihen: `docs/flatten-regeneration-measurements.md`.

## Offene Punkte

**Braiding-Kalibrierung (behoben, weiter beobachten):**
Die Kapazität des Murray-&-Paola-`braidPass` wurde auf `5e-6` gesenkt. Damit
lagern überlastete, flache Reaches wieder Bänke ab. `testBraidingBuildsBars`
misst seit Aug 2026 MULTI-SEED: die Einzel-Seed-Zählung flippte unter jeder
kleinen Physik-Störung (gemessen 9v3 → 2v4 durch das Verlandungs-Gate).

Nach dem Vegetations-Merge (PR #1) war der Wächter rot (Inseln an=7 vs. aus=14).
Headless-Diagnose (12 Seeds, an/aus): der Pass war NICHT schwächer geworden
(Braiding-Arm 36 → 37 Inseln), der KONTROLLARM ohne Braiding sammelte
Fehlalarme (19 → 31), obwohl dort nie ein Bänke-Pass läuft. Ursache: die
Auwald-Klasse landete auch auf den Wasserlauf-Zellen SELBST, womit die
kohäsivste Erosions-Dämpfung (1.3) auf Gerinne und Talboden lag — der Talboden
panzerte sich, stehen gebliebene Knubbel im breiten MFD-Lauf zählten als
„Insel". Korrektur in `updateVegClass`: GEHÖLZ (Wald wie Auwald) ist Ufer-,
keine Bett-Klasse — Bett-Zellen bleiben Gras (Faktor 1.0 = exakt die
Vor-Merge-Dämpfung), dieselbe Doktrin wie der Bett-Kill in `meanderStamp`.
Nur Auwald auszuschließen reichte nicht: dichte Bett-Zellen fielen dann auf
Wald (1.1) und blieben teil-gepanzert (an 79 vs. aus 50, Seeds 6:3 — ein Flip
von der Kante); erst die vollständige Entpanzerung gibt klaren Abstand.
Verworfen (gemessen): die Klassen-Dämpfung im `braidPass` selbst zurückzunehmen
— das machte den Kontrast SCHLECHTER (an 7→5 bei aus 14) und hätte einen realen
Effekt gelöscht (Ufer-Vegetation stabilisiert Bänke, Tal & Paola 2007).

Der ehemals offene Punkt „Bank-Fläche als robustere Metrik" ist damit erledigt:
der Wächter misst Bank-FLÄCHE über 16 Seeds und fordert zusätzlich einen
Mindestabstand von 3 Seeds (an 160 vs. aus 81 = 1.98×, Seeds dafür 9 /
dagegen 3, Inseln 62 vs. 33, Splits 3352 vs. 3059, ~33 s). Am Regressions-Stand
trennte die Insel-ZAHL nur 1.19×, die Fläche 1.77× — eine echte Mittelbank ist
mehrzellig, ein Ufer-Knubbel ein bis zwei Zellen. Optional weiter offen:
Splits pro Trunk-Länge als zusätzliche Metrik.

**Terrain-Alterung — ERLEDIGT (Aug 2026, Issue #13):** Die Landschaft altert
jetzt von selbst, statt von einem Regler auf dem jungen Zustand gehalten zu
werden. Belegtabellen: `docs/terrain-aging-measurements.md`, Kalibrier-Logbuch:
`Config.swift` bei `upliftDecayStartPer100y`, Wächter: `TerrainAging`.
- **Abklingende Hebung** `U(t) = U_floor + (U₀−U_floor)·e^(−t/τ)` mit
  U₀ = 0.0008, U_floor = 0.00008, τ = 40.000 J. ersetzt den Servo als
  Haupt-Tektonik. `step()` integriert U(t) über den Schritt geschlossen →
  framerate-unabhängig.
- **Die offene Entscheidung ist getroffen: Start am Orogenese-Höhepunkt.** Die
  Generierung liefert den fertigen scharfen Gebirgszustand, es gibt keine
  Aufbauphase — U(t) klingt ab t=0 ab, also gibt es per Konstruktion keinen
  Wachstums-Puls. Gegenprobe gemessen: U₀ = 0.006 hebt maxH 0.6836 → 0.7647 und
  meanLand +18 % (= „Berge wachsen", verworfen), U₀ = 0.003 dreht ab 20k wieder
  hoch (verworfen). Bei U₀ = 0.0008 ist der maxH-Spitzenwert des Laufs über alle
  5 gemessenen Seeds exakt der Startwert.
- **Relief-Servo ist nur noch UNTERGRENZE** (`reliefTarget` 0.20 → 0.05): mit
  dem alten Ziel lief er in JEDEM Schritt und löschte die Alterung komplett
  (Relief bei 200k 0.4961 statt 0.3359). Bei 0.05 springt er im normalen
  100k/200k-Fenster nie an und fängt nur noch echte Peneplanation ab.
- **`isoHighClamp` (0.90) bleibt** — testweise auf 10 (praktisch aus) gemessen:
  der Gipfel wächst dann zwischen 20k und 60k wieder (0.6334 → 0.6426) und das
  Relief plateaut bei ~0.49 statt zu altern. Seine Rolle hat sich geändert: nicht
  mehr Runaway-Deckel, sondern Bremse gegen erneutes Anheben der höchsten Grate.
- **Diagnose-Kennzahl `Terrain.ridgeCurvature()`** (mittleres ∇²z auf
  Gratzellen, negativ = spitz, gegen 0 = rund) gebaut und im Diagnosepanel
  sichtbar. Sie trennt „jung spitz" von „alt rund" objektiv: n=832 über 100k
  neu −0.0508 → −0.0389 (rundet monoton), alt −0.0517 → −0.0476 mit Umkehr ab
  40k. Noch offen: die hypsometrische Kurve als zweite Alterungs-Kennzahl.

**Niederschlagsgewichteter Abfluss — ERLEDIGT (Issue #9 Mechanik, Issue #10
Kalibrierung, Aug 2026):** `SimConfig.rainWeightedFlow` ist **an** und gewichtet
die Akkumulation beider Netze (`Terrain.seedFlowAccumulator`, D8 und MFD nach
derselben Regel — die Rollentrennung bleibt) sowie die Erosions-Tropfen
(`Hydraulic.spawnPosition`, Ablehnungs-Stichprobe). Aus `area` wird Abfluss statt
Fläche. Messreihe: `docs/rain-weighted-flow-measurements.md`; Wächter:
`RainWeightedFlow.swift`.
- Belegt: bei gleich großem Einzugsgebiet trägt die Luvseite ×1.38 (D8) bzw.
  ×1.42 (MFD) mehr Abfluss; die Drainagedichte Luv/Lee verschiebt sich gepoolt
  über 6 Seeds von 1.048 auf 1.362 und in Produktionsauflösung (n=832) in allen
  12 gemessenen Zeitschnitten Richtung Luv (×1.20 … ×1.52).
- **Die Rekalibrierung ist eine NORMIERUNG, keine Konstanten-Verschiebung**
  (#10): Gewicht = `rain / Landmittel(rain)` auf Land, 1.0 über See
  (`Terrain.updateRainWeight`). Damit ist Σ Gewicht über Land = Zahl der
  Landzellen (`totalOutletArea/Zellzahl` = 1.0000 an wie aus), und der Anteil der
  Tropfen-Starts auf Land ist gleich dem Anteil der Landzellen — der Schalter
  verteilt nur um. Folge: KEIN Zell-Gate (`renderMinCells`, `braidMinCells`,
  `meanderMinCells`, `floodplainMinArea`), keine Rate (`kRock`, `outletErode`)
  und keine Tropfendichte (`hydraulicPerYear`) musste nachgezogen werden;
  Kanalzellen bleiben in Produktionsauflösung im Band ±10 %, Relief ±5 %.
- Warum nicht das rohe Feld gewichten: das Landmittel des Regens ist
  auflösungs-, seed- UND zeitabhängig (0.563 bei n=192 → 0.357 bei n=832 Seed
  1337, aber 0.544 bei Seed 7; +24 % Drift über 50k Jahre). Gegenprobe mit auf
  einen Seed gerechnetem Gate: −13.6 % / +18.5 % / +5.8 % Kanalzellen über drei
  Seeds (Details und weitere verworfene Wege: Doku §G).
- Nebenbefund aus #10: `kRock` wirkt im Produktionspfad gar nicht — die Konstante
  steht nur in `transportLimited` (Nicht-Droplet-Zweig). Die fluviale Rate der
  Produktion ist `outletErode`.
- Offen geblieben: `computeRain` ist nicht weltmaßstäblich (Abtrocknung je ZELLE
  statt ∝ `cellSize`), das rohe `rain` bleibt damit auflösungsabhängig für
  Vegetation und Biom-Färbung. Die Verdunstungsseite von „Niederschlag −
  Verdunstung" (PLAN §3b) ist mit #11 für SEEN erledigt, für Hang/Boden offen.

**Verdunstung in abflusslosen Becken — ERLEDIGT (Aug 2026, Issue #11):**
Becken-Wasserhaushalt `A_zu ≥ κ · Σ_Seezellen cellArea · aridity` je
zusammenhängender Senke; der Spiegel ist der höchste Stand, dessen Seefläche die
Verdunstung noch aus dem Zufluss deckt. Messreihen:
`docs/endorheic-evaporation-measurements.md`, Wächter: `EndorheicEvaporation`.
- **κ = 1.25** (Verhältnis Seeverdunstung : mittlere Abflusshöhe = nötiges
  Einzugsgebiet:Seefläche). Kalibriert an der gemessenen RATIO-VERTEILUNG: die
  tiefen Becken dieser Landschaft liegen dicht über 1 (1.63/1.93/2.2 bei n=832),
  die Fluss-Pools bei 5…800 — ab κ=1.5 kippen alle tiefen Becken gleichzeitig
  (sichtbare Seefläche 10.4 → 0.5 %), bei κ ≤ 0.5 ist der Pass ein No-op. κ=1.25
  hält die Seen (sichtbar 10.04 gegen 10.36 % bei 20k) und macht 2 Becken
  endorheisch (3625 Salzpfannen-Zellen). κ ist damit auch der KLIMA-Regler:
  trockene Welt = größeres κ (die Mechanik-Wächter fahren κ=6).
- Verdunstungs-limitierte Becken sind terminale Senken: `receiver` = −1, kein
  MFD-Überlauf, keine Auslass-Inzision → ein endorheisches Becken entwässert sich
  nicht selbst frei (real: Tarim, Death Valley bestehen über Jahrmillionen).
- Der Generierungs-Breach bleibt verdunstungs-BLIND (er misst seinen Fortschritt
  am See-Anteil und würde sonst nach der ersten Runde abbrechen: gemessen 87684
  trockengefallene Zellen schon bei der Generierung). Zwei Zeitebenen:
  antezedente Entwässerung vs. heutiges Klima.
- Der Bilanz-Spiegel ist ratenbegrenzt (`endorheicResponseYears` = 500 J.,
  dt-invariant), der Darstellungs-Spiegel hängt in Serie dahinter.
- Rendering: `saltCrust` (EWMA, nur trockengefallener Boden mit Vollstand-Tiefe
  > 0.03) malt die helle Playa in `terrainColorBytes`; Salzpfannen bleiben kahl
  (Vegetations-Ziel × (1 − Kruste)).
- Offen: Sediment-Haushalt der Playa (Evaporite/Schwemmfächer), seed-breite
  Luv/Lee-Messreihe für `endorheicAridity`, Nachmessen der Spätphase nach dem
  Zufluss-Fix (s. Doku §E) — und die **Wechselwirkung mit dem Braiding**:
  `testBraidingBuildsBars` pinnt den Wasserhaushalt aus, weil die Bank-Fläche an
  der Wasserfläche hängt (an=124/aus=84 statt 160/81, Seeds 6:5 statt 9:3 — der
  Pass bleibt stärker als ohne, aber die Seed-Mehrheit reißt).

**Lithologie-Feld — ERLEDIGT (Aug 2026, Issue #12):** die Erodierbarkeit ist nicht
mehr global. Ein deterministisches, seed-abhängiges Gesteinsfeld
(`Terrain.buildLithologyField` fix je Seed, `Terrain.updateLithology` je Schritt)
moduliert Erodierbarkeit UND Hangdiffusivität. Messreihe:
`docs/lithology-measurements.md`, Wächter: `Lithology.swift`.
- Aufbau: **geneigte, gefaltete Schichtpakete** (stratigraphische Koordinate
  `s = (h − Schichtebene)/lithLayerThickness`, Streichen/Fallen je Seed) plus
  großräumige **Härte-Provinzen** (Noise, `lithProvinceMix` = 0.35) →
  `hard ∈ [−1,1]`, `K = 1 − 0.6·hard`, `D = 1 − 0.45·hard`.
- Dass `s` an der aktuellen HÖHE hängt, ist der Mechanismus: die harte Bank bleibt
  auf ihrem Niveau, während das weiche Gestein darunter ausgeräumt wird — die
  Kante verlegt sich seitwärts (Schichtstufe/Mesa) statt mit der Oberfläche
  abzusinken.
- Gelesen wird das Feld von `outletIncision` (fluviale Makro-Rate), `Hydraulic.erode`
  (nur der FELS-Anteil des Abtrags, Sediment bleibt Sediment), `hillslopeDiffusion`
  und `transportLimited` (Testpfad). Sediment-/Ufer-/Küstenpässe (Braiding, Wave,
  Mäander-Carve, Verlandung) bleiben bewusst unberührt.
- Belegt: Hangknick-Signal (Steigung hart/weich, lokal gepaart, geometrisch
  gepoolt) 0.999 → **1.163** über 20k Jahre gegen 1.004 → 1.052 im Referenzarm
  (`lithContrast = 0`, bit-identisch zum Aus-Zustand). Beide Extreme halten den
  Relief-Wächter: weichstes Gestein Relief 0.364, härtestes 0.441 nach 100k Jahren
  (n=160, Schwelle 0.30).
- Der Diffusions-Kontrast trägt zum Knick **nichts messbares** bei (1.163 gegen
  1.180 ohne ihn) — er bleibt als physikalische Kopplung drin, ist aber als
  unbelegt dokumentiert, nicht als Notwendigkeit behauptet.
- Rückwirkung: die #11-Wächter und der Braiding-A/B **pinnen das Feld aus** (sie
  hängen an einem konkreten Becken bzw. an einer Seed-Mehrheit); dass beide
  Mechaniken MIT Feld intakt bleiben, ist eigens gemessen (Braiding-Kontrast steigt
  sogar auf 1.67×). Details: `docs/lithology-measurements.md` §E.
- Offen: Gegenprobe in Produktionsauflösung (n=832) und über mehrere Seeds,
  Parameter-Sweeps (Paketdicke, Fallen, Kontrast), Rückverlegungsrate einer
  Stufenkante als schärfere Kennzahl, härteabhängige Küstenklippen (`wavePass`).

**Politur / Rendering:**
- ERLEDIGT (Aug 2026): „Hüpfende" See-/Schwemmflächen — Deposition am Becken-Auslass
  (Droplets+Braiding+Mäander gemeinsam, keine Einzelquelle) schüttet den Sill zu,
  Priority-Flood hebt `hf` instantan fürs ganze Becken, outletIncision schneidet in
  ~100 J. zurück (Sägezahn). Fix: ratenbegrenzter Darstellungs-Seespiegel
  `Terrain.waterLevel` (`lakeLevelResponseYears`, 250 J.), Physik bleibt auf `hf`;
  Wächter: `LakeLevelStability`.
- ERLEDIGT (Aug 2026): „Wachsender Boden ohne Wasser" — die Pfützen-Verlandung hob
  die kilometerbreiten Sub-0.06-Ufersäume der großen Seen als Ganzes an (90% der
  Tiefland-Hebung; ΔVol über 20k J. halbiert: +131→+68). Fix: `fillShallowPonds`
  verlandet nur noch Wasser-Komponenten OHNE See-Kern (< `puddleLakeCoreCells`
  tiefe Zellen); See-Ufer verlanden nur noch physisch über Droplet-Deltas.
  Ein träges Verlandungs-Ziel (waterLevel) und Größen-Schwellen waren gemessene
  Sackgassen (wirkungslos bzw. Braid-Bänke beschädigt, s. Config-Kommentare).
- **Deltas** an Fluss-Mündungen in Meer/Seen sichtbar machen (das Transport-Modell baut
  sie schon, das Rendering hebt sie nicht hervor).
- See-Ränder minimal gezackt (per-Zelle-Quads) — zu einer Kontur glätten.
- Steile Oberläufe der Fluss-Geometrie leicht segmentiert — feinere Glättung oder
  adaptive Unterteilung.
- ERLEDIGT (Aug 2026, Issue #4): Schnee-, Hochfels- und Vegetations-Höhengrenzen
  kommen aus **Perzentilen der aktuellen Landhöhen** (`HeightBands`,
  `SimConfig.band*Percentile`) statt aus absoluten Werten. Die alte Schneegrenze
  1.05 lag über jedem je erreichten Gipfel (maxH 0.7457 bei der Generierung,
  0.6372 nach 30k) und blieb dauerhaft leer. Ausnahme mit Begründung: die BREITE
  der Vegetations-Rampe kommt aus der robusten Relief-Spanne (p95 − p50) statt
  aus einem zweiten Perzentil — ein Perzentil dort hinge an den obersten paar
  Zellen und verschob messbar die Erosion (`docs/height-band-measurements.md` §5).
  Jetzt ist die Gipfelzone konstant
  1.5 % des Landes (0.15 % voll weiß) und sinkt mit der alternden Landschaft mit.
  Sim-Kern und Biom-Färbung lesen dieselbe Quelle
  (`Terrain.vegetationSuitability` / `Terrain.heightBands`), statt zwei Kopien
  derselben Höhen-/Hang-Logik zu pflegen. Messreihe:
  `docs/height-band-measurements.md`.
- Optik-Feinschliff: Grün-Anteil in den Tälern, Küstensaum-Breite.

**Toter/geparkter Code (aufräumen oder bewusst behalten):**
- ERLEDIGT (Aug 2026): `streamPower` (detachment-limitierte Grid-Inzision) und
  `thermalPass` (Schwellen-Talus) ENTFERNT — beide waren seit ihrer Ablösung
  unreferenziert. Im Produktionspfad übernimmt die fluviale Makro-Inzision
  `outletIncision` + `Hydraulic.erode` (Droplet); `transportLimited` ist NICHT
  der Nachfolger, sondern ein Testpfad (siehe unten, Commit `eaa3425`).
  `thermalPass` → lineare Diffusion, Commit `cf83874`. Mit `thermalPass` sind die
  nur von ihm gelesenen Config-Schalter `talus`/`thermalRelax`/`rockCrumble`
  entfallen (Küsten-Talus `waveTalus` bleibt). Talus machte planare Facetten statt
  konvexer Kuppen — falls je wieder gewünscht (Steilfels-Kappen), aus `cf83874^`
  holen.
- `transportLimited` + `diffusionPass` laufen NUR im Nicht-Droplet-Zweig
  (`hydraulicEnabled = false`). Kein toter Code: die isolierten Mäander-
  Kopplungstests (`meanderCfg()` in `SimCoreTests.swift`) prüfen darauf Carve/
  Altarm/Altern ohne Droplet-Rauschen. Als Testpfad im Code kenntlich gemacht.
- `fillLakes` (Becken-Verlandung) hängt an `basinFill = false` und läuft damit derzeit
  NIRGENDS (auch in keinem Test) — bewusst GEPARKT, nicht vergessen: AUS, seit die
  Hebung niedrig ist (Auslass-Inzision hält den See-Anteil von allein bei ~15%
  diskreten Seen), aber der dokumentierte Rückfall für Konfigurationen mit hoher
  Hebung. Begründung im Config-Kommentar.
- `floodplainAggradation` liegt deaktiviert als Referenz herum (`floodplainEnabled=false`):
  per-Zell-Aggradation fügte gemessen 2.7× Zerklüftung/Krusten hinzu. Die Auen kommen
  jetzt über sanfteres Relief (`baseRelief` 0.78).

**Backlog (nicht priorisiert):**
- Gletscher / glaziale Erosion → U-Täler, Kare, Moränen.
- Gekachelte Welt mit LOD + GPU-Compute für die Grid-PDEs (1024²+ in Echtzeit).
- Klima-Jahreszeiten → schwankender Abfluss, Schneedecke, Hochwasser.
- Speichern/Laden von Welten.
- Gameplay (falls gewünscht): Ziele/Szenarien statt reinem Sandbox.

## Verifikation

- **Headless-Tests:** `cd SimCore && swift test -c release` (Debug ist bei n=832 zu
  langsam). Beim Iterieren `--filter <methodName>` — **nicht** den Klassennamen, der
  matcht 0 Tests. Wächter: `LongRunCollapse.swift` (kein Runaway/Kollaps),
  `RiverDynamicsTests.swift` (MFD-Splits, Braiding-Bänke, Becken→Meer, Stream-Map,
  Mäander in Produktion).
- **Extension bauen** (~3,5 min): `./scripts/build.sh release` — **immer mit absolutem
  Pfad aufrufen.** Relativ aus `game/` heraus schlägt es still fehl, und die Screenshots
  laufen dann mit der ALTEN dylib (hat schon 3 „wirkungslose" Iterationen gekostet).
  Auf die „gebaut + signiert"-Zeile prüfen.
- **Screenshots headless** (Godot via Steam):
  ```
  GODOT="$HOME/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot"
  RS_STEP=<jahre> RS_SHOT=/pfad/shot.png RS_DIST=<kameradistanz> "$GODOT" --path game
  ```
  `RS_STEP` steppt die Sim vor dem Shot (Jahr 0 vs. gesteppt vergleichen!). Das Jahr-Label
  bleibt dabei auf „Jahr 0" (`_ready` ruft `_update_year` nicht) — kein Bug.
  Springen/Dynamik sind nur in BEWEGUNG sichtbar, nicht im Standbild.
- **App interaktiv:** `"$GODOT" --path game` (oder `--editor`).
- **Shader-Debug-Rezept:** ALBEDO im Shader auf `(riverMask, lakeMask, stream)` legen;
  `RS_NO_MEANDER_PAINT=1` schaltet die Mäander-Stempel für A/B ohne Rebuild ab.

## Wichtige Dateien

- `SimCore/Sources/SimCore/Terrain.swift` — `generate()`, `step()`, `computeFlow`,
  `outletIncision`, `braidPass`, `meanderStamp`, `diffusionPass`.
- `SimCore/Sources/SimCore/Hydraulic.swift` — Droplet-Erosion (Textur + Stream-Map + Pools).
- `SimCore/Sources/SimCore/Meander.swift` — Lagrange-Zentrumslinie, Migration, Cutoff.
- `SimCore/Sources/SimCore/ErosionFilter.swift` — runevision-Pre-Erosion (Phacelle Noise).
- `SimCore/Sources/SimCore/Config.swift` — **alle** Stellschrauben, jede mit Begründung.
- `Extension/Sources/RiverSimGD/SimNode.swift` — `terrainColorBytes` (Palette),
  `waterFieldBytes` (Wasser-Feld, EWMA, Render-Schwellen).
- `game/shaders/terrain.gdshader` — Wasser-Overlay, Detail-Layer, Shading.
- `game/scripts/Main.gd` — Licht/Environment, UI, Kamera/Zoom, RS_*-Env-Schalter.

## Arbeitsweise in diesem Projekt (ernst nehmen)

- **Erst headless messen, dann schrauben.** Die visuelle Hypothese war mehrfach falsch
  (der „Kuppel-Kollaps" war ein Runaway; die „Punktfeld-Blobs" waren Mäander-Stempel,
  nicht Seen). Kennzahlen über die Zeit loggen (Relief, Ruggedness, See-Anteil, meanLand).
- **Nicht zaghaft** („MVP vom MVP"), aber auch nicht blind an Details schrauben, wenn das
  Gesamtbild nicht stimmt.
- Bei „30 % besser statt 1 %" auf **echte Recherche mit Primärquellen** gehen (`docs/`),
  nicht weiter am Symptom drehen.
- **Kalibrier-Kaskade beachten:** Änderungen am Droplet-Pfad verschieben die
  Braiding-Kalibrierung, Rinnen-Textur bricht Formeln, die Per-Zell-Steigung als „Hang"
  lesen (Regen/Vegetation/Biom-Farbe brauchen Makro-Steigung über ±2 Zellen).

## Recherche (in den Ansatz eingeflossen)

- `docs/research-braided-meandering-rivers.md` — Freeman/Quinn MFD, Tarboton D-∞,
  Murray & Paola (zelluläres Braiding), Ikeda/Howard (Mäander), Nicholas-Kontinuum.
- `docs/research-terrain-aging.md` — Theodoratos 2018, Whipple & Tucker, Braun & Willett;
  Kennzahl `l_c = D/K` (klein = jung/zerklüftet, groß = alt/rund).
- `docs/river-baseline-metrics.md` — Baseline-Messung vor dem Fluss-Overhaul
  (Churn 0.2725 bei jedem dt = Framerate-Kopplung des alten D8-argmax).
- `docs/rain-weighted-flow-measurements.md` — Messung an/aus zum
  niederschlagsgewichteten Abfluss: Kanalzellen, Drainagedichte Luv/Lee, Relief,
  Seeanteil. §A–§D = Issue #9 (roher Regen als Gewicht, der verworfene Arm),
  §E–§G = Issue #10 (Normierung, Verlauf in Produktionsauflösung, verworfene
  Alternativen).
- `docs/references/runevision-erosion/` — kompletter GLSL-Code des Erosionsfilters
  (MPL-2.0), Grundlage von `ErosionFilter.swift` und des Shader-Detail-Layers.
- nickmcd.me (Procedural Hydrology, Meandering Rivers), SebLague/Elumenix (Droplet).
