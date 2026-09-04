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
  Uplift → Lithologie → Flow (inkl. Becken-Wasserhaushalt) → Seespiegel/Playa →
  Eis → Mäander → SPL/Auslass → Verlandung → Braiding → Droplet → Auen →
  Diffusion → Wave → Klima → Vegetation. Das **vollständige** `step()`-Diagramm
  mit der Begründung je Einhängepunkt steht in `AGENTS.md` § SimCore-Aufbau —
  dort mitziehen, wenn ein Pass dazukommt.
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
  **Wasser-Geometrie (Issues #31/#34, STANDARD seit Aug 2026):** Mäander,
  Delta-Distributäre und Altarme als Band-Geometrie direkt aus den
  Zentrumslinien (`SimNode.buildRiverRibbons` → `water.gdshader`), Breite ∝
  √Abfluss (Leopold/Maddock), Strahler-Ordnung (`Strahler.swift`, headless
  getestet) als Rang-Maß (nur an Ordnung 3 angeschlossene Bänder — bis Aug
  2026 Ordnung 4, gesenkt mit dem Korridor-Umbau, s. `ribbonMinimumRank`;
  deren feine
  Oberläufe bleiben), kanalweise Stream-Map-Kohärenz gegen verknäulte Altpfade,
  lokale Geländehöhe je Bandkante — seit Aug 2026 geklemmt auf eine maximale
  Quer-Neigung (`ribbonMaxCrossSlope`), damit ein Band, das breiter als die
  Schluchtsohle ist, nicht die Wände hochdrapiert — sowie Ufer-Übergang über
  Saum-Stempel + Kanten-Feathering (gegen die Rückbau-Ursachen von `f3556c8`).
  Dirty-Vertrag wie bei den Bäumen (`riversMaxDelta`/`markRiversBuilt`), im
  Zeitraffer auf 1 Hz gedeckelt.
  **Korridor nur unter echten Bändern (Aug 2026):** der Saum-Stempel des
  Wasserfelds und sein Raster-Deckel folgen dem ECHTEN Bau-Ergebnis
  (`RiverRibbonRenderer.bandChannelFlags`); vom Strahler-/Kohärenz-Gate
  verworfene Kanäle gehören ganz dem D8/MFD-Raster (vorher: Saum ohne Wasser
  auf 52 % der sichtbaren Zentrumslinien-Zellen). Das Raster zieht sichtbare
  Läufe seither über die geklemmte Kontinuitäts-Kette bis zum offenen Wasser
  durch, und die Verbreiterung prüft ihre Bank-Toleranz symmetrisch (kein
  Bergab-Ausfächern an Steilwänden mehr).
  **Deckel ANTEILIG statt binär (Aug 2026):** der Raster-Deckel nimmt nur so
  viel Wasser zurück, wie das Band an dieser Zelle wirklich deckt
  (`RiverRibbonRenderer.bandCoverage`, dieselbe Doktrin eine Ebene feiner als
  `bandChannelFlags`). Der binäre Deckel entfernte 94 469 Korridor-Zellen
  gegenüber 10 307 verbleibenden Fluss-Zellen — dort, wo das Band-Alpha
  ausläuft (Enden-Taper, Abfluss-Rampe, Kohärenz, Kaskaden-Übergabe), malte
  weder Band noch Raster und der Lauf riss ab (User: „keine durchgehenden
  Adern"). Danach: sichtbares Fluss-Wasser 10 307 → 21 970 Zellen, größte
  zusammenhängende Fluss-Komponente 454 → 4 102 Zellen (Seed 1337, Jahr 20 000).
  Nachtrag: die Deckung wird mit der TATSÄCHLICH emittierten Halbbreite
  gestempelt, also nach dem Krümmungs-Deckel darunter — mit der ungedeckelten
  meldete das Band an engen Schlingen Deckung für einen Streifen, den es nicht
  malt, und der anteilige Deckel riss dort dieselbe Lücke wieder auf, die er
  schließen soll. Und gestempelt wird das SEGMENT zwischen zwei Stützpunkten
  (Abstand zur Strecke, Halbbreite und Alpha entlang der Strecke interpoliert),
  nicht ein Kreis um den Punkt: bei stark greifendem Deckel (Halbbreite ≲ 0,3
  Zellen) fielen die Kreise auseinander und ließen die Streifenkante ungedeckt
  — dort bliebe Raster-Wasser unter dem Band stehen. Wächter für beides:
  `WaterRenderTests.testCoverageStampUsesTheWidthTheBandPaints` (Quelltext der
  Brücke; die Geometrie selbst prüft `game/tests/river_ribbons.gd` in CI).
  **Band-Breite am Krümmungsradius gedeckelt** (`ribbonCurvatureWidthFactor`):
  wo ein Band breiter war als der Radius seiner Schlinge, überschlugen sich
  seine Quads zu Fächern spitzer Dreiecke (User: „hässliche Dreiecke");
  zusätzlich hat die Tangenten-Berechnung jetzt eine Rückfallkette für
  Haarnadeln (zentrale Differenz degeneriert dort zu 0).
  **Altarme:** eigener Sicht-Horizont `WaterRender.oxbowVisibleYears` = 6000
  statt des Listen-Alters `oxbowMaxAge` = 25 000, und Mindestgröße von 10 auf
  20 Knoten — vorher standen 1322 Altarme gleichzeitig als glänzende Flächen in
  der Ebene („Altarm-Teppich"), jetzt ~70.
  **Übergabe an das Raster-Feld (#34):** ein Band malt genau das Flachwasser,
  das der See-Kanal nicht malen darf (Wassersäule unter `rawWet` = 0.03), und
  blendet dort aus, wo dieser übernimmt — deshalb ist `deltaFrontDepth` DIESELBE
  Zahl. Am Meer (eigene Wasser-Ebene, deckt ab der ersten Zelle) blendet es
  stattdessen nach Strecke aus (`mouthOverlapCells`). Der Vertex-Vertrag trägt
  den Typ in UV2.x (Fluss/Delta/Altarm); Altarme kodieren Fließrichtung 0 und
  werden vom Shader als Stillwasser gemalt.
  `RS_WATER_STAMP=1` schaltet auf den alten Raster-Stempel-Pfad zurück (A/B im
  selben Build) — Messprotokoll: `docs/geometry-water-measurements.md`.
- **Karte:** n = 720 bei worldSize 112,4789 (cellSize ≈ 0.156 — Auflösung und
  Weltgröße immer ZUSAMMEN ändern, sonst brechen alle per-Zell-Kalibrierungen).
  Vorher 832/130; gesenkt für Rechenzeit (63,6 → 47,6 ms/Schritt, Insel 74,9 %
  der Fläche, cellSize unverändert). Messreihe und die beiden Folgeänderungen
  (`lakeLevelResponseYears`, `world`-Pin in den Testkonfigs) im Config-Logbuch.
  Ältere Messwerte in diesem Dokument, die „n = 832" nennen, sind Protokolle
  ihres Stands und bleiben so stehen.
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
  MultiMesh (`treeInstanceBuffer`, deterministischer Hash-Jitter, Waldklasse statt
  pauschal `veg`, Strand-/Auen-/Hang-Ausschluss, reduzierte Standardansicht;
  Umschalten keine/reduziert/voll per UI oder Taste V, Rebuild nur bei Max-Δveg > 0.1).
- **Speichern/Laden (Issue #8):** eine Welt geht vollständig in EINE versionierte
  Binärdatei (`WorldSnapshot.swift`) — das ganze Zustands-Inventar
  (`TerrainState`, ~25 Felder à n²) plus Mäander-Zentrumslinien/Altarme, Seed und
  **Config**. Abnahme-Invariante ist Bit-Determinismus: geladen weiterlaufen ==
  durchgehend simuliert (`WorldSnapshotTests`). Ratenbegrenzte Zustände
  (`waterLevel`, `lakeBalance`) reisen mit, damit die Seespiegel nach dem Laden
  nicht einschwingen. Ältere Formatversionen werden abgelehnt, nicht
  interpretiert; geschrieben wird atomar. UI: 💾/📂 bzw. F5/F9.
  Details: `docs/world-save-format.md`.
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

**Seed 1337 ist ein See-Ausreißer (Aug 2026, gemessen — offen: Entscheidung).**
Der Default-Seed (`RenderContract.defaultSeed`) erzeugt die mit Abstand
nasseste Welt des Feldes. Anteil sichtbar nasser Landzellen nach 20 000 Jahren
und größte Wasser-Komponente (n = 832, Produktions-Config):

| Seed | Landzellen | nass | Anteil | größter See |
| ---: | ---: | ---: | ---: | ---: |
| **1337** | 479 778 | 79 689 | **16,6 %** | **46 853** |
| 7 | 224 834 | 777 | 0,35 % | 35 |
| 99 | 318 319 | 18 789 | 5,9 % | 5 755 |
| 2024 | 226 121 | 13 907 | 6,2 % | 5 083 |
| 4242 | 152 010 | 3 474 | 2,3 % | 3 164 |

Damit ist „zu viel stehendes Wasser" beim Start KEINE Fehlkalibrierung der
Physik, sondern die Eigenschaft dieser einen Welt: ein Riesenbecken fängt sie
ab. Der naheliegende Physik-Hebel dagegen ist im Kalibrier-Logbuch bereits
gemessen und verworfen (`SimConfig.outletErode` ×1.4 senkte den Seeanteil bei
20k praktisch nicht und kostete Kanalzellen und Relief). Offen ist deshalb eine
PRODUKT-Entscheidung, keine Kalibrierung: Default-Seed auf eine repräsentative
Welt umstellen (die Tests pinnen ihre Seeds selbst) oder 1337 als bewusst
seenreiche Startwelt behalten.

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

**dt-Invarianz — ERLEDIGT bis auf zwei benannte Reste (Aug 2026, Issue #2):**
gleiche Simulationszeit lieferte je nach Schrittweite anderes Terrain. Vier
Ursachen behoben, jede mit eigenem Wächter (`SimCoreTests/DtInvariance.swift`,
Messreihen `docs/dt-invariance-measurements.md`):
- `wavePass` war eine ZÄHLSCHLEIFE (`max(1, min(24, dt/100))` Durchläufe voller
  Stärke) statt einer Rate → jetzt sub-getaktet wie die Hangdiffusion
  (`Terrain.waveSchedule`). Küstenzone über dt ∈ {10, 240, 2000}: Spanne 38 % →
  **1.0 %**.
- `fillShallowPonds`/`fillLakes`/`fillOxbows`/`updateVegetation` relaxierten
  linear gedeckelt (`min(cap, dt/τ)`) statt exponentiell (`1 − e^(−dt/τ)`);
  `floodplainAggradation` (geparkt) ist mitgezogen. Die τ-Werte sind
  unverändert, die Config-Kommentare halten die neue Bedeutung fest.
- Tropfenzahl `max(1, dt·Rate)` rundete jeden Frame-Schritt auf (bei dt = 0.2 J.
  11× zu viel) → angebrochener Rest wandert über `Terrain.dropCarry` weiter.
  Ebenso der Tropfen-STROM: sein Seed hing an einem Schritt-Zähler (leere
  Schritte schoben ihn weiter, ein großer Schritt zog alle Tropfen aus EINEM
  Strom) → jetzt an der laufenden Nummer des Tropfens
  (`Terrain.dropsEmitted`/`Hydraulic.dropRNG`), Tropfen Nr. j ist damit
  derselbe, egal wie die Charge geschnitten wird (bit-identisch geprüft).
- Schritt-Deckel („halbe lokale Höhendifferenz") in `meanderStamp`/`braidPass`
  galten je Schritt → `Terrain.stepCapFraction` (bei dt = 100 exakt die alten
  0.5); die Überfüll-Zugabe in `braidPass` ist jetzt eine geometrische
  Obergrenze — genau der Stauraum `hf − h` — statt einer Zugabe je Schritt
  (der alte `+0.005` lag über dem aktuellen `h`, wuchs also mit der
  SCHRITTZAHL weiter, sobald die Schüttung den Spiegel erreicht hatte).
- Kalibrier-Kaskade (wie erwartet): vier Wächter reagierten. Der Depositions-
  Deckel ist deshalb der reine Stauraum ohne Konstante: eine feste Obergrenze
  `hf + X` verschiebt je nach X die Kalibrierung in verschiedene Richtungen
  (X = 0.006 machte den Bilanz-Spiegel der abflusslosen Becken sprunghaft —
  4 Sprünge > 0.0015 statt 0 —, X = 0.02 kippte die Bett-Reconciliation), und
  keine dieser Höhen ist physikalisch begründet. Der Scour-Deckel in
  `braidPass` bleibt deshalb bei festen 0.5 (Erosionsseite, #2 nennt die
  Depositions-Deckel), der Anker von `stepCapFraction` liegt bei 500 J. statt
  100, und `testBraidingBuildsBars` taktet mit dt = 500 statt 1000 — bei 1000
  hing die Pfützen-Verlandung vorher am `min(0.5, …)`-Deckel, wodurch der
  REFERENZARM (ohne Braiding) trockene Flächen dazugewann (94 → 212) und den
  A/B-Kontrast überdeckte. Details und Zahlen: `docs/dt-invariance-measurements.md`
  §6/§7.
- **Rest 1 — offen, bewusst nicht Teil von #2: Operator-Splitting-Drift.** Das
  Abflussfeld wird einmal je Schritt bestimmt, die Tropfen laufen `dt·Rate` mal
  dagegen — bei dt = 2000 arbeiten 360 Tropfen auf einem Feld, das dt = 10 alle
  1.8 Tropfen neu berechnet. Gemessen ist das der ganze Rest-Unterschied: der
  Seeanteil liegt ohne Tropfen über zwei Dekaden Schrittweite auf 1.6 %
  zusammen, bei 0.2 Tropfen/Jahr auf 2.3 %, bei den 2.0 der Produktion auf 29 %
  (auf dem vollen Pfad verstärkt durch die Schwellen-Logik von
  `fillShallowPonds`: eine Komponente mit See-Kern verlandet gar nicht mehr).
  Nächster Schritt wäre, die Tropfen-Charge eines großen Schritts in Teilchargen
  mit zwischenzeitlichem `computeFlow` zu zerlegen — Eingriff in die
  Schritt-Struktur mit Laufzeit-Folgen (`computeFlow` ist der teuerste Pass),
  gehört in ein eigenes Issue. Zweiter, kleinerer Verstärker: das See-Kern-Gate
  der Pfützen-Verlandung ist eine BINÄRE Klassifikation je Schritt (mit Gate
  0.0211/0.0212/0.0503 über dt ∈ {10, 240, 2000}, ohne Gate
  0.0044/0.0045/0.0046) — es bleibt unangetastet, weil es die Antwort auf
  „wachsender Boden ohne Wasser" ist.
- **Rest 2 — bewusst stehen gelassen: der Scour-Deckel in `braidPass`.** Er
  begrenzt den Braid-Abtrag auf feste 0.5 der lokalen Höhendifferenz JE SCHRITT
  und ist als EINZIGER Deckel nicht auf `Terrain.stepCapFraction` umgestellt:
  #2 hat die DEPOSITIONS-Deckel geradegezogen, dies ist die Erosionsseite. Als
  Rate darf ein 200-Jahr-Schritt 0.75 statt 0.5 ausräumen; gemessen gräbt der
  Scour damit die Böden der abflusslosen Becken tiefer, die trockengefallene
  Playa-Fläche fiel von >100 auf 35 Zellen und die #11-Wächter
  `testDriedBedIsRenderedAsPlaya`/`testBasinLevelIsRateLimited` kippten
  (`docs/dt-invariance-measurements.md` §6, Zeile zum Scour-Deckel). Die
  Schrittweiten-Abhängigkeit ist damit klein, bekannt und am Code kommentiert —
  wer sie beseitigen will, braucht eine eigene Kalibrier-Runde für die
  endorheischen Becken, kein reines Umstellen auf den Helfer.

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
- ERLEDIGT (Aug 2026, Issue #34): **Deltas** an Fluss-Mündungen in Meer/Seen sichtbar
  — als Distributär-Fächer der Geometrie über dem Ablagerungskörper (Wassersäule
  zwischen Uferlinie und `deltaFrontDepth`), Trübungsfahne statt zweiter
  Wasserfläche. Gemessen wurde vorher, WORAN man ein Delta erkennt: an einer
  Tiefen-Schwelle gar nicht (flache Buchten ohne Fluss sehen genauso aus), wohl
  aber am Saum, den das Raster-Feld nicht malen kann
  (`docs/geometry-water-measurements.md` §A). Im selben Zug geschlossen: der
  Spalt zwischen Band-Ende und Uferkontur (Mündungs-Verlängerung dem
  D8-Empfänger entlang, Wächter zählt 0 statt 8) und das doppelte Wasser über
  Seeflächen.
- ERLEDIGT (Aug 2026, Issue #32): See-Ränder minimal gezackt (per-Zelle-Quads) — die
  Uferlinie entsteht jetzt PRO PIXEL im Shader aus `waterLevel − h` auf dem vollen,
  bilinear gefilterten Sim-Gitter (`pond_at` in `terrain.gdshader`, Shader-Äquivalent
  zu Marching Squares) statt aus einer zell-quantisierten Maske. Der G-Kanal des
  Wasserfelds trägt nur noch das Sichtbarkeits-GATE (Komponenten-Fade), nicht mehr
  die Tiefe; kleine Wasserflächen faden über 12→24 Zellen ein, statt bei 25 hart zu
  ploppen. Vertex-Lift und Farbe teilen sich das Gate, sonst bliebe eine trockene
  horizontale Fläche im Becken stehen. OFFEN dabei geblieben: der Vertex-Lift selbst
  läuft weiter auf dem RENDER-Gitter (384/256) — die Silhouette der Seefläche bleibt
  dort gerastert, die per-Pixel-Kontur überdeckt sie nur. Nebenwirkung gemessen und
  behalten: weil der G-Kanal jetzt ein gesättigtes Gate ist, bekommen Seen erstmals
  einen Ufer-Saum (`shore`) — vorher fiel er an Seen aus, s.
  `docs/lake-shore-contour-measurements.md`.
- Steile Oberläufe der Fluss-Geometrie leicht segmentiert — feinere Glättung oder
  adaptive Unterteilung. (Stand #34: die Catmull-Rom-Unterteilung mit 3 Samples je
  Knoten und der Alpha-Längsfilter aus #31 sind unverändert; die Segmentierung
  fällt nur noch am steilen Oberlauf auf, wo die Bänder ohnehin fadendünn sind.)
- OFFEN nach #34: der Delta-Fächer läuft in GERADEN Armen aus der Mündungs-
  richtung — seine Form kommt aus der Länge des Ablagerungskörpers, nicht aus
  einer eigenen Distributär-Dynamik. Ein echtes Verzweigungsmodell (Arme, die
  sich beim Aufschütten selbst verlegen) wäre Sim-Arbeit, keine Render-Arbeit,
  und gehört in ein eigenes Issue.
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
  **Nachtrag Issue #33:** der SCHNEE ist seither kein Perzentil mehr — s. den
  nächsten Punkt. Die übrigen Bänder (Vegetation, Fels, Nadelbaum) bleiben
  unverändert perzentil-gekoppelt.
- ERLEDIGT (Aug 2026, Issue #33): **Klima-Vertikale als Prozess.** Temperaturfeld
  aus der Höhe (`T₀ − Γ·(h − sea)`, Kalibrier-Entscheidung 1 Höheneinheit ≙
  4000 m bei ICAO-Gradient 6,5 K/km → Γ = 26 K/Einheit) und Schneedecke als
  Massenbilanz (Akkumulation aus `rain` bei Frost, Ablation als
  degree-day-Ratenkonstante, exakt dt-invariant in der Form
  `S* + (S−S*)e^(−μdt)`). Schnee-Färbung liest jetzt das FELD je Zelle
  (Luv/Lee-Signal sichtbar), die Waldgrenze die daraus zurückgerechnete Höhe.
  Der Flächenanteil ist damit GEMESSEN statt gesetzt: n=832/Seed 1337 1.39 %
  (Jahr 0) → 0.90 % (30k), während `snowStart` bei 0.572 stehen bleibt (vorher:
  Fläche konstant 1.5 %, Grenze wanderte nach unten). Kein Erosionspass liest das
  Klima — bewusste Scope-Grenze, die Kopplung kommt mit dem Eis (#35).
  `climateEnabled = false` ist bit-identisch zum Stand davor.
  Recherche `docs/research-climate-cryosphere.md`, Messreihe
  `docs/climate-snow-measurements.md`.
  **Nachtrag Issue #36:** „kein Erosionspass liest das Klima" gilt nicht mehr —
  die SCHMELZE speist den Abfluss, s. den nächsten Punkt.
- ERLEDIGT (Aug 2026, Issue #36): **Schmelzwasser speist den Abfluss.** Die
  Ablation der Schneedecke (`snowMeltPerKYear · max(0,T) · S`, in Regen-Einheiten
  über `snowAccumPerYear` umgerechnet — der Grundumsatz-Sockel bleibt draußen, er
  ist Sublimation bzw. Firn→Eis für #35) geht in das Abfluss-Gewicht ein. EIN
  Trichter (`Terrain.flowWeight`, gebaut in `updateRunoffWeight`) speist beide
  Netze (D8 `area` → Erosion, MFD `areaMFD` → Render/Braiding) und die
  Tropfen-Startpunkte. Designentscheidung gemessen: **Renormierung** (Landmittel
  des rohen Gewichts → 1) statt Zusatzwasser — Σ Abfluss bleibt exakt die
  Zellzahl, kein in Zellen kalibriertes Gate musste nachgezogen werden, und die
  Wirkung ist dieselbe (Abfluss je Einzugszelle schneegespeist/schneefrei gepoolt
  über 5 alpine Seeds 0.838 → 0.959, also +14.5 %; Zusatzwasser-Arm 0.965 bei
  Σ = 1.008 … 1.018). Verworfen mit Messwerten: die massenkonsistente Einlagerung
  des Festniederschlags (`meltRunoffWithholdSolid`) dreht das Vorzeichen (0.765) —
  ohne Eistransport schmilzt der Schnee, wo er fällt, und die Dauerfrostzone
  verliert ihren Abfluss an einen Speicher ohne Ausgang. Mit #35 wird dieser Arm
  richtig. `meltRunoffEnabled = false` ist bit-identisch zum Stand davor.
  Messreihe `docs/melt-runoff-measurements.md`.
  Reichweite (gemessen): nur ~40 % der Seeds haben bei n=192 überhaupt Schnee,
  ~12 % sind alpin — auf flachen Inseln ist das Feature stumm.
- ERLEDIGT (Aug 2026, Issue #35): **Gletscher — Eisfluss und glaziale Erosion.**
  `Terrain.ice` ist kein Platzhalter mehr: `updateIce` läuft zwischen Abflussfeld
  und fluvialer Makro-Inzision und macht in EINEM sub-getakteten Takt drei
  Dinge — Firn→Eis aus dem Schneevorrat (nur unter 0 °C), TRANSPORT auf der
  Eis-Oberfläche `h + ice` (Zwei-Phasen-Scratch wie die Hangdiffusion,
  Ausstrom ∝ Dicke × Gefälle, Positivitäts-Deckel je Säule) und ABRASION nach dem
  Flux-Modell (`E = K·q^0.5·S`, Härtefaktor nur auf dem Fels-Anteil). Was
  ausschmilzt, legt seine Schuttfracht als **Moräne** ab — im Zehrgebiet, unter
  dem Nährgebiet per Konstruktion nicht. Die Maske `Terrain.underIce` legt den
  fluvialen Abtrag unter dem Eis still — `outletIncision` und `Hydraulic.erode`
  prüfen sie direkt, alle übrigen Bett-Bewegungen (Mäander-Carve und -Ufer,
  Altarme, Braid-Fracht, Auen-Aggradation, im Testpfad auch `transportLimited`)
  über ihren gemeinsamen Funnel
  `erodeCell`/`depositCell`; leer heißt aus, also bit-identisch wie bei
  `isChannel`. NICHT gegatet ist die Hangdiffusion — Bodenkriechen ist kein
  fluvialer Pass, trägt aber Nachbar-Änderungen auf die Eiszelle
  (`docs/glacier-measurements.md` §I.1).
  * Der TRANSPORT ist bewusst ein linearer Diffusions-Pass mit KONSTANTEM kappa,
    nicht die SIA — deren `H^{n+2}`-Zeitschritt-Deckel hat
    `docs/research-climate-cryosphere.md` §4.1 verworfen. Ohne Transport gäbe es
    aber gar keine ZUNGE (gemessen: 968 gegen 63 Zellen unter der Firn-Grenze),
    deshalb reicht die reine Flux-Akkumulation der Recherche nicht.
  * Die **V→U-Kennzahl** (Formexponent `b` des Querprofils, V = 1, U = 2) trennt
    sich über den ganzen Lauf vom eisfreien Referenzarm: Δb +0.22 … +0.30 über
    10k…50k Jahre. Nötig dafür war der lateral ausgestrichene Erosions-Streifen
    (`iceErodeSwathRadius`), den §4.3 der Recherche vorhergesagt hat — die rein
    lokale Flux-Rate schneidet im Thalweg eine Kerbe und machte das Profil
    V-IGER.
  * Kosten: +18 ms je 500-Jahr-Schritt und +0.84 s je `+10.000-Jahre`-Sprung bei
    n = 640; im Echtzeit-Zeitraffer ein einziger Teilschritt.
  * `iceEnabled = false` — und ebenso jede Welt ohne Eis — ist bit-identisch zum
    Stand vor #35. Messreihe `docs/glacier-measurements.md`.
  Offen geblieben: die Gleichgewichts-DICKE ist auflösungsabhängig
  (∝ `1/(n−1)`, die Fließstrecke in Welteinheiten dagegen nicht) — beschränkt,
  aber bei kleinem `n` dickeres Eis, s. Messreihe §B.
- Optik-Feinschliff: Grün-Anteil in den Tälern, Küstensaum-Breite.

**Speichern/Laden (Issue #8, erledigt Aug 2026) — was offen bleibt:**
- **Ein Speicherplatz** (`user://saves/welt.rsworld`), kein Dateidialog und keine
  Slots/Namen — eine eigene UI-Frage, nicht Teil von #8.
- **Keine Kompression.** Eine Welt ist das vollständige Zustands-Inventar
  (gemessen 166 Byte je Zelle, bei n=832 also ~109 MB). zlib würde das grob
  halbieren,
  bringt aber eine System-Bibliothek ins bewusst abhängigkeitsfreie SimCore-
  Package. Erst machen, wenn die Dateigröße real stört.
- **Keine Aufwärts-Migration.** Eine Datei aus einer anderen Formatversion wird
  abgelehnt (nicht interpretiert), die Datei-Config ist beim Laden autoritativ —
  Änderungen an `SimConfig()`-Defaults wirken damit nur auf NEUE Welten.
  Begründung und Kanten: `docs/world-save-format.md`.
- Speichern blockiert den Frame, in dem es passiert (bei n=832 spürbar). Ein
  Hintergrund-Thread wäre möglich, braucht aber eine Kopie des Zustands.

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
- `puddleFillSkipsFlowCells = false` (Issue #108, Sep 2026): der Pfützen-Ausschluss
  in wasserführenden Flussbetten ist verdrahtet und GEPARKT. Er ist der stärkste
  der drei Hebel gegen das zugeschüttete Bett (Quereinschnitt bei 100k 0.086 →
  0.158 Welt-Y), lässt aber das Wasser in den Bett-Pits STEHEN: die Übergabe
  Band ↔ Raster malt dann doppelt (Kennzahl 0.024 → 0.243) und die dt-Invarianz
  des See-Anteils reißt. Offen ist der Pass, der die Pits ENTWÄSSERT statt sie
  nur nicht mehr zu füllen; danach ist der Hebel nachzumessen
  (`docs/channel-incision-measurements.md` §E).

**Sim-Schritt-Laufzeit — Runde 3 (Aug 2026, Issue #43): ~41 % schneller, Ziel
knapp verfehlt, Rest benannt.**
Der Sim-Schritt blockiert den Hauptthread und ist **Fixkosten**: gemessen kostet
dt = 0,2 praktisch dasselbe wie dt = 100 (400,4 vs. 426,1 ms bei n = 832 auf der
Linux-VM) — im Echtzeit-Zeitraffer zahlt also jeder Frame den vollen Schritt.
Diese Runde hat ihn ohne jede Physik-Änderung (Wächter: `simperf --hash`,
Fingerabdruck über alle Zustandsfelder) um **~41 %** gesenkt — A/B in einer
Sitzung: 426/440/432 → 258/251/258 ms bei dt = 100, 400 → 241 ms bei dt = 0,2.
Das Ziel des Issues („mindestens halbiert") ist damit **knapp verfehlt**;
Messprotokoll, Werkzeug und die Liste der gemessenen **Fehlschläge** stehen in
`docs/perf-measurements.md`.

Der Befund war fast überall derselbe: die Zeit lag nicht in der Arithmetik,
sondern in Bounds-, COW- und Exklusivitätsprüfungen bei Zugriffen auf
KLASSEN-Properties im Zell-Loop (~40 Zyklen je Zugriff; eine Mehrfeld-Schleife
über das Gitter kostet ~9 ms JE FELD und Schritt). Wer einen neuen Gitterpass
schreibt, öffnet seine Felder einmal per `withUnsafe*BufferPointer` — die
Helfer `Terrain.fill`/`Terrain.anyCell` decken die Memset-/Suchfälle ab.

Was bewusst NICHT angetastet wurde:
- **`priorityFlood`** (jetzt der größte Posten) ist unter der Bit-Identitäts-
  Auflage ausgereizt. Die bekannten Beschleunigungen (Priority-Flood + FIFO nach
  Barnes, cache-ausgerichteter/8-ärer Heap) ändern die Pop-Reihenfolge bei
  gleichen Keys — und `order` ist die SUMMATIONSREIHENFOLGE der
  Flächen-Akkumulation, also Rundung. Messdaten zum Heap in `docs/perf-…` §F.
- **`mfdUpdateInterval`** steht auf 1; `computeMFDArea` läuft also auch ohne
  Braiding jeden Schritt (die Vermutung aus Issue #43, `braidingEnabled` hebele
  ein Intervall aus, trifft nicht zu). Ein größeres Intervall wäre eine
  Physik-Änderung und braucht eine eigene Kalibrier-Runde.
- Alles, was mit `dt` skaliert (`Hydraulic.erode`), ist für die Echtzeit-FPS
  ohnehin nicht der Treiber.

Nächste Hebel, wenn wieder Laufzeit gebraucht wird: Sim-Schritt vom
Render-Thread entkoppeln (Doppelpuffer), oder die drei verbliebenen seriellen
`order`-Pässe (`priorityFlood`, `computeMFDArea`, `outletIncision`) mit einer
BEWUSSTEN Physik-Neukalibrierung angehen.

**Struktur & Härtung — ERLEDIGT (Aug 2026, Issues #49–#53).** Fünf Tickets ohne
Physik-Änderung; sie haben Einzelquellen hergestellt und die Zusagen, die vorher
im Review standen, in Wächter überführt. Was seitdem gilt:
- **#49 — SwiftGodot exakt gepinnt** (`exact: "0.76.1"`, `Package.resolved`
  eingecheckt) statt `branch: "main"`. Der Pin wird nur bewusst und in einem
  eigenen Commit angehoben; Prozedur in `AGENTS.md`.
- **#50 — SimCore-Härtung:** `Terrain.relaxFraction` ist die EINZIGE Quelle der
  exponentiellen Relaxation (`RelaxationTests`), `Terrain.macroSlope` die einzige
  Quelle der Makro-Steigung, und die Becken-Rolle ist ein Typ (`BasinRole`) statt
  roher Codes — inklusive Weg in den Spielstand. Neue Wächter für vorher
  ungetestete API: `TerrainAPITests` (Generierung, Pinsel `smooth`/`roughen`,
  Abkling-Rate der Hebung).
- **#51 — Render-Kalibrierung zentralisiert:** jede Schwelle, Breite und
  Wasser-Optik-Konstante steht in `WaterRender`/`RenderContract`. Seit #80/#82
  führen `WaterRenderTests` und `WaterRendererTests` die Swift-Seite direkt aus;
  Quelltext-Vergleiche bleiben für `.gdshader` und `Main.gd`. Seit #91/#92
  reisen die Wasser-Werte als `water_*`-Uniforms über die Brücke
  (`SimRender.WaterUniforms` → `SimNode` → `Main.gd`), die Shader deklarieren
  sie default-frei und an Shader-Quelltext wird nur noch STRUKTUR verglichen
  (welche Stelle welche Uniform liest); die frühere Schreibweisen-Regel gilt
  nur noch für die restlichen `glsl(_:)`-Pins (`Main.gd`-Konstanten,
  `hscale`-Default).
- **#52 — CI verifiziert den Godot-Vertrag** (Job `godot-contract`) und nicht mehr
  nur den Sim-Kern; Godot-Version und -Prüfsumme sind in `scripts/fetch-godot.sh`
  gepinnt, Build-Stempel-Parität Shell ↔ GDScript ist getestet, und Mess-/Sweep-Läufe
  (Namensendung `Diagnostic`) sind hinter `RS_MEASURE=1` aus der Pflichtsuite heraus
  — beide Richtungen bewacht von `MeasurementGateTests`. Budget: `docs/ci-measurements.md`.
- **#53 — dünne Bridge wiederhergestellt:** `SimNode.swift` ist wieder Marshalling,
  die Render-Aufbereitung liegt je Pfad in einem eigenen Modul (s. „Wichtige
  Dateien"), die Werkzeug-Tabelle hat mit `BrushTool` + `ToolContractTests` einen
  Vertrag zwischen `Main.gd` und Swift. Für Umbauten daran ist
  `res://tests/render_fingerprint.gd` das A/B-Werkzeug (SHA-256 je Render-Puffer,
  vorher/nachher vergleichen) — kein Wächter, die Hashes gelten je Maschine.

**Godot-freie Render-Aufbereitung — ERLEDIGT (Aug 2026, Issues #80/#82).**
`SimRender` ist ein eigenes Target im SimCore-Paket: Farbe, Bäume, Diagnostik,
Raster-Wasser und Band-Geometrie laufen ohne SwiftGodot und werden in der
Pflichtsuite als Verhalten getestet. Die Band-Geometrie liefert `RibbonMesh`
aus SIMD-POD-Puffern; `SimNode` wrappt nur noch in `Packed*Array`. Die
Band↔Raster-Verträge (kein Spalt, kein Doppel-Wasser, Ufer-/Mündungs-Einigkeit)
laufen in `WaterRendererTests` und bleiben zusätzlich als Godot-End-to-End-Tests
bestehen. `render_fingerprint.gd` baut die Bänder seit #80 vor den Texturen wie
die Produktion; die dadurch einmalig geänderten Hashes bilden die neue
Vorher-Baseline für den bit-identischen Umzug.

**Render-Zustand bei seinem Besitzer — ERLEDIGT (Aug 2026, Issue #93).**
`SimRender.RenderState` besitzt die vier zustandstragenden Renderer und den
Material-Cache des zustandslosen `TerrainColorRenderer`; die
GDExtension hält keinen Render-Zustand mehr und meldet jede Terrain-Änderung an
den EINEN Einstieg `invalidate(terrain, worldReplaced:)`. Damit ist die alte
Asymmetrie aufgelöst — Neu-Generieren verwirft die Dirty-Snapshots jetzt wie das
Laden, statt sich auf die Delta-Heuristik zu verlassen — und die feste
Pass-Reihenfolge nach einem Pinselstrich liegt als
`Terrain.recomputeFlowAfterEdit()` in SimCore. Wächter:
`RenderStateTests` (Verhalten + Quelltext-Probe der Brücke) und
`TerrainAPITests`. Prefactor für den Frame-Vertrag (#94).

**Backlog (nicht priorisiert):**
- Gekachelte Welt mit LOD + GPU-Compute für die Grid-PDEs (1024²+ in Echtzeit).
- Klima-Jahreszeiten → schwankender Abfluss, Schneedecke, Hochwasser.
- Gameplay (falls gewünscht): Ziele/Szenarien statt reinem Sandbox.

## Verifikation

- **CI** (`.github/workflows/ci.yml`, Issue #52): bei jedem Push auf `main` und
  jedem PR laufen parallel der Sim-Kern (Job `test`) und der Godot-Vertrag (Job
  `godot-contract`: GDExtension-Build, Projekt-Import, Build-Stempel-Parität,
  `smoke.gd`/`water_geometry.gd`/`river_ribbons.gd`). Mess-/Sweep-Tests
  (Namensendung `Diagnostic`) sind aus der Pflichtsuite heraus und laufen nur mit
  `RS_MEASURE=1`. Laufzeit-Budget und Zahlen: `docs/ci-measurements.md`.
- **Laufzeit:** `SimCore/.build/release/simperf --repeat 3` (Mess-Harness aus
  Issue #43: Produktions-Config mit `n`/`world` aus `SimConfig()` selbst,
  Einlauf + Pass-Tabelle) und `simperf --hash` als Bit-Identitäts-Wächter
  vor/nach einer Optimierung. Protokoll und Messhygiene:
  `docs/perf-measurements.md`.
- **Headless-Tests:** `swift test -c release --package-path SimCore -Xswiftc
  -swift-version -Xswiftc 5` (Debug ist bei diesen Grids zu langsam, der
  Swift-5-Schalter Pflicht — Begründung in `AGENTS.md` § Befehle). Beim Iterieren
  `--filter <methodName>` — **nicht** den Klassennamen, der
  matcht 0 Tests. Wächter: `LongRunCollapse.swift` (kein Runaway/Kollaps),
  `RiverDynamicsTests.swift` (MFD-Splits, Braiding-Bänke, Becken→Meer, Stream-Map,
  Mäander in Produktion), `WorldSnapshotTests.swift` (Spielstand läuft
  bit-identisch weiter, alte Formatversion wird abgelehnt),
  `TerrainAPITests.swift` (Generierung, Pinsel `smooth`/`roughen`,
  Abkling-Rate der Hebung) und `RelaxationTests.swift` (der gemeinsame
  Relaxations-Helfer `Terrain.relaxFraction`).
- **Extension bauen:** `"$(git rev-parse --show-toplevel)"/scripts/build.sh release`
  — **immer mit absolutem Pfad aufrufen.** Relativ aus `game/` heraus schlägt es
  still fehl, und die Screenshots laufen dann mit der ALTEN Library (hat schon 3
  „wirkungslose" Iterationen gekostet); dagegen steht seit Issue #52 zusätzlich der
  Build-Stempel. Auf die „gebaut"-Zeile am Ende prüfen. Laufzeiten je Rechner und
  Änderungsumfang: `AGENTS.md` § Befehle.
- **Screenshots headless** (Godot-Binärdatei aus `scripts/fetch-godot.sh`, der
  einzigen Quelle der gepinnten Version):
  ```
  GODOT="$(scripts/fetch-godot.sh)"
  RS_STEP=<jahre> RS_SHOT=/pfad/shot.png RS_DIST=<kameradistanz> "$GODOT" --path game
  ```
  `RS_STEP` steppt die Sim vor dem Shot (Jahr 0 vs. gesteppt vergleichen!). Das Jahr-Label
  bleibt dabei auf „Jahr 0" (`_ready` ruft `_update_year` nicht) — kein Bug.
  Springen/Dynamik sind nur in BEWEGUNG sichtbar, nicht im Standbild.
- **App interaktiv:** `"$GODOT" --path game` (oder `--editor`).
- **Shader-Debug-Rezept:** ALBEDO im Shader auf `(riverMask, lakeMask, stream)` legen;
  `RS_NO_MEANDER_PAINT=1` schaltet die Mäander-Stempel für A/B ohne Rebuild ab,
  `RS_WATER_STAMP=1` den ganzen Wasser-Renderpfad zurück auf das Raster (#34).
- **Ausschnitt-Screenshots:** `RS_TARGET="x,z"` setzt den Blickpunkt in
  Weltkoordinaten (Höhe wird auf das Gelände gehoben), `RS_YAW`/`RS_PITCH` den
  Orbit — damit ist eine Mündung reproduzierbar im Bild. Mit `RS_SHOT` blendet
  sich die Bedienleiste aus.

## Wichtige Dateien

- `SimCore/Sources/SimCore/Terrain.swift` (~4500 Zeilen) — `generate()`, `step()`,
  `computeFlow`, `updateIce`, `outletIncision`, `braidPass`, `meanderStamp`,
  `updateClimate`, `updateVegetation`, `diffusionPass` (Testpfad).
- `SimCore/Sources/SimCore/Hydraulic.swift` — Droplet-Erosion (Textur + Stream-Map + Pools)
  und `HydraulicParams`, die Tropfen-Stellschrauben.
- `SimCore/Sources/SimCore/Meander.swift` — Lagrange-Zentrumslinie, Migration, Cutoff.
- `SimCore/Sources/SimCore/ErosionFilter.swift` — runevision-Pre-Erosion (Phacelle
  Noise) und `ErosionFilter.Params`.
- `SimCore/Sources/SimCore/HeightBands.swift` — Perzentil-Höhenbänder (Issue #4).
- `SimCore/Sources/SimCore/Config.swift` (~1500 Zeilen) — `SimConfig`, die
  Stellschrauben mit Begründung. Zwei Gruppen liegen bewusst bei ihrem Code
  (s. `AGENTS.md` § Konfiguration).
- `SimCore/Sources/SimCore/WorldSnapshot.swift` — Welt-Speicherformat (Magic,
  Version, Prüfsumme, atomares Schreiben); das Zustands-INVENTAR (`TerrainState`)
  steht am Ende von `Terrain.swift`.
- `SimCore/Sources/SimCore/WaterRender.swift` + `RenderContract.swift` +
  `Strahler.swift` — Render-Ableitungen ohne Sim-Zustand; seit Issue #51 die
  EINZIGE Quelle der Render-Kalibrierung, aus `SimCoreTests` gegen das
  ausführbare `SimRender`, Shader und `Main.gd` gepinnt.
- `SimCore/Sources/SimRender/` — godot-freie Render-Aufbereitung:
  `RenderState` als Besitzer des Render-Zustands (Issue #93) über
  `WaterFieldRenderer`, `RiverRibbonRenderer` + POD-`RibbonMesh`,
  `TerrainColorRenderer`, `TreeInstanceRenderer`, `TerrainDiagnostics` und
  `RenderSupport` als gemeinsame Ufer-/Mündungslogik.
- `Extension/Sources/RiverSimGD/SimNode.swift` — dünne Brücke (`@Callable`s,
  Aufrufweitergabe und `Packed*Array`-Marshalling), ohne eigenen
  Render-Zustand; daneben bleibt nur `BrushTool` als Routing der
  Godot-Werkzeugmodi.
- `game/shaders/terrain.gdshader` — prozedurale Boden-/Fels-/Vegetations-/
  Kältematerialien, Lithologieschichten, Wasser-Overlay und Detail-Layer;
  `water.gdshader` — Band-Geometrie; `ocean.gdshader` — opakes offenes Meer,
  unter Land per gemeinsamer Höhenkarte ausgeschnitten.
- `game/scripts/Main.gd` (~1280 Zeilen) — Licht/Environment, UI, Kamera/Zoom,
  Werkzeug-Tabelle, RS_*-Env-Schalter.
- `game/tests/*.gd` — die Godot-seitigen Wächter (`smoke`, `water_geometry`,
  `river_ribbons`, `build_stamp_parity`, `tree_count`, `water_rings`,
  `pickaxe_repro`) plus `render_fingerprint.gd` als A/B-WERKZEUG (kein Wächter).

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
