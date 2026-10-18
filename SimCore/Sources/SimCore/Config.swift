import Foundation

/// Alle kalibrierbaren Konstanten des Simulationskerns an einem Ort.
/// Höhen sind normiert (~ -0.3 .. 1.4). Weltkoordinaten in abstrakten Einheiten.
///
/// `Codable`/`Equatable` sind Codable-SYNTHESE für das Weltformat (Issue #8,
/// `WorldSnapshot.swift`): die Config reist vollständig im Spielstand mit, und
/// zwar automatisch — eine neue Stellschraube hier braucht keinen Eintrag im
/// Serialisierer. Die Konformität steht deshalb absichtlich HIER (Swift
/// synthetisiert nur in der Ursprungsdatei) und nicht als Extension dort.
public struct SimConfig: Sendable, Codable, Equatable {
    // n und world ZUSAMMEN von 832/130 auf 720/112,4789 gesenkt (Aug 2026):
    // cellSize 112,4789/719 = 0,156438 == 130/831 auf sechs Stellen, alle
    // per-Zell-Kalibrierungen (Braid-Gates, Droplet-Dichte, kappa) gelten also
    // unverändert weiter — was schrumpft, ist die INSEL (74,9 % der Fläche),
    // nicht das Detail.
    //
    // Grund: Rechenzeit. GEMESSEN interleaved (simperf, M4 Max, Minimum aus je
    // drei Läufen): 832 → 63,6 ms/Schritt, 720 → 47,6 (1,34×), 640 → 37,6
    // (1,69×). Die Kosten folgen n² auf 0,1 ms. Sim-Speicher 243 → ~182 MB.
    // 640/100 (die Paarung vor 832/130) war ebenfalls im Vergleich: dort
    // verschwand die Seenkette im Inneren sichtbar, bei 720 bleibt sie —
    // deshalb der Zwischenwert und nicht der schnellere.
    //
    // ACHTUNG bei weiteren Umstellungen: `world` allein verschiebt die
    // ZELLGRÖSSE jedes Tests, der nur `n` pinnt. Deshalb pinnen die Testkonfigs
    // seit dieser Runde `world` mit (s. SimCoreTests/TestCalibration.swift), und
    // `lakeLevelResponseYears` musste mitgezogen werden (s. dort).
    public var n: Int = 720          // Grid-Auflösung (n × n) — hoch für feines dendritisches Detail
    public var world: Double = 112.4789   // Kantenlänge in Welteinheiten — gehört zu `n` (Begründung und Messreihe im Block darüber). Historie der Paarung: 640/100 → 832/130 (Insel ~1,7× größer) → 720/112,4789. cellSize blieb bei allen dreien ~0,1564; die auf n=640 kalibrierten Per-Zell-Parameter gelten seit damals unverändert.
    public var sea: Double = 0.15     // Meeresspiegel (normiert)
    public var floor: Double = -0.3   // tiefster Punkt (Tiefseegraben)

    // ---- Terrain-Generierung ----
    public var baseOctaves: Int = 9    // viele Oktaven → feine Grate bis zur Auflösungsgrenze
    public var baseFreq: Double = 3.5  // Grundfrequenz (× 1/n)
    /// Großform der Generierung (Issue #174, `RangeSkeleton` in `Landform.swift`):
    /// EIN Gebirgskamm entlang der langen Inselachse mit Seitenästen, Hügelland
    /// daneben, flache Ebene dahinter, zwei bis vier Täler vom Kamm zur Küste;
    /// die Tektonik (`upliftBase`) liegt nur noch im Gebirgsgürtel. Dazu ein
    /// Randabstand (kein Land am Gitterrand) und eine Insel-Ellipse, die über
    /// ihre LANGE Halbachse normiert ist.
    ///
    /// Gemessen (Produktion, Seeds 1337/42/20, `docs/zielbild-measurements.md`):
    /// Landanteil der vier größten Tieflandflächen in Jahr 2000 13/32/26 % →
    /// 48/62/52 %, und erst jetzt erreicht eine davon die Küste (Reichweite
    /// 0,00 → 1,00). Land im Randring 659/0/280 → 0 Zellen. Eis in Jahr 100.000
    /// auf Seed 42 0 → 529 Zellen. `LongRunCollapse` bleibt grün.
    ///
    /// `false` = die Form davor (Grate über die ganze Landfläche), bit-identisch.
    /// Nur für die Mechanik-Wächter der Testsuite, deren Testwelt Becken,
    /// Playas und Schlingen der alten Seed-1337-Welt braucht
    /// (`calibrationRangeLandform` in `SimCoreTests/TestCalibration.swift`).
    public var rangeLandform = true
    public var baseRelief: Double = 0.78 // vertikale Reliefstärke. Von 1.05 gesenkt (User: „zu extrem"): sanfteres Terrain → weniger Nadel-Gipfel UND flachere/breitere Talböden (niedrigere Slopes → mehr Reaches unter der Mäander-Schwelle) = Platz für Fluss-Dynamik. 0.72 ebnete über 100k knapp unter den LongRunCollapse-Wächter (0.30); 0.78 hält Marge.
    public var upliftFreq: Double = 2.5

    // ---- Pre-Erosion (runevision-Erosionsfilter bei der Generierung) ----
    // Carvt verzweigte Rinnen/Grate einmalig ins frische Basisrelief (stacked
    // faded gullies, ErosionFilter.swift) → das Terrain startet mit erodiertem
    // Look statt ihn über 10k+ Sim-Jahre einzucarven. Die Sim läuft danach
    // normal weiter (Droplets folgen den vorgecarvten Rinnen).
    public var preErodeEnabled = true
    public var preErodeParams: ErosionFilter.Params = ErosionFilter.Params()

    // ---- Stream-Power-Inzision (detachment-limited, FastScape) ----
    // dz/dt = U − K·A^m·S^n ;  n = 1 (implizit, unbedingt stabil)
    public var mExp: Double = 0.5      // Flächen-Exponent m
    // #10 (gewichteter Abfluss): GEPRÜFT, unverändert — und dabei gemessen, dass
    // kRock im PRODUKTIONSPFAD gar nicht wirkt: die Konstante steht nur in
    // `transportLimited`, dem Nicht-Droplet-Zweig (`hydraulicEnabled = false`),
    // den nur die Mäander-Kopplungstests fahren (die ihre eigene Konfiguration
    // pinnen). Gegenprobe: kRock 3.5e-5 → 4.9e-5 (die aus #9 §D.2 gerechnete
    // Kompensation ×1.4) ändert an n=832/Seed 1337 über 20k Jahre KEINE
    // Kennzahl — Kanalzellen 16329/25258/27184, Relief 0.5957/0.5312/0.4981
    // identisch mit dem Default-Lauf. Die fluviale Rate der Produktion ist
    // `outletErode` (dort steht die #10-Messung).
    // Was die Umverteilung mit dem Relief macht (die eigentliche Frage): 50k
    // Jahre, n=832, Produktionspfad, aus → an — Seed 1337 0.4574 → 0.4592
    // (robust 0.1484 → 0.1558), Seed 7 0.3499 → 0.3521, Seed 99 0.2858 → 0.2937.
    // Durchweg unter +3 %: die Normierung hält Σ Abfluss = Σ Fläche, A^m sieht
    // im Mittel dieselbe Größe wie vorher.
    public var kRock: Double = 3.5e-5  // Erodierbarkeit Grundgestein (niedriger → hohes Gleichgewichts-Relief, rugged bleibend)

    // ---- Multi-Flow-Drainage (nur Render/Braiding, NICHT Erosion) ----
    // Freeman(1991)/Holmgren(1994): der Abfluss wird STETIG an alle tieferen
    // Nachbarn verteilt (fᵢ = Sᵢᵖ/ΣSⱼᵖ) statt komplett an den steilsten (D8-argmax).
    // Das erlaubt (a) Aufspalten um Mittelbänke + Wiedervereinen (mit D8 unmöglich)
    // und (b) stetiges Gleiten des Laufs statt Springen (D8 würfelt ~27% der
    // Empfänger je Flow-Update neu — gemessen). Speist NUR `areaMFD` (Wasserfeld);
    // die Inzision bleibt bewusst Single-Flow, damit der kalibrierte Terrain-Look
    // und die implizite FastScape-Stabilität unangetastet bleiben.
    public var mfdExponent: Double = 4.0 // p→∞ = D8, p=1.1 max dispersiv (Braiding-Regime), p≈4 hält den dendritischen Look. Auf flachen großen Läufen gilt stattdessen braidDispersion (Terrain.mfdLocalExponent).
    /// Ohne Braiding darf das reine Render-MFD seltener aktualisiert werden. Mit
    /// Braiding bleibt es immer frisch, weil es dort ein physikalisches Feld ist.
    /// Core-Default bleibt 1 für eine frische API.
    public var mfdUpdateInterval: Int = 1
    // ---- Niederschlagsgewichteter Abfluss (Issue #9, kalibriert #10) — Default AN ----
    // AN (Default seit #10): die Akkumulation beider Netze startet je Zelle mit
    // `cellArea · rainWeight[k]` (D8 UND MFD, dieselbe Regel — die Rollentrennung
    // bleibt: `area` speist die Erosion, `areaMFD` nur Render/Braiding), und die
    // Tropfen starten niederschlagsgewichtet (Ablehnungs-Stichprobe in
    // `Hydraulic.erode`). Aus `area` wird damit ABFLUSS statt Fläche —
    // physikalisch Q = ∫ P dA, die Standard-Lesart von A^m in der Stream-Power.
    // AUS: reine ZELLFLÄCHE wie vor #9 (bit-identisch, Wächter
    // `testUnweightedAccumulationIsPureCellArea`). Der Schalter BLEIBT, obwohl er
    // in Produktion nie aus ist: die ungewichtete Akkumulation ist der
    // Referenzarm, mit dem alle Messungen hier belegt sind — ohne ihn ließe sich
    // nicht mehr zeigen, dass die Luv-Richtung aus dem REGEN kommt und nicht aus
    // der Insel-Geometrie (in `testRainWeightedFlowFavorsLuv` ist der Aus-Arm die
    // Gegenprobe mit exakt 1.0).
    //
    // DIE REKALIBRIERUNG (#10) IST EINE NORMIERUNG, KEINE KONSTANTEN-VERSCHIEBUNG.
    // Gewicht = `rain / Landmittel(rain)` auf Land, 1.0 über See
    // (`Terrain.updateRainWeight`). Damit gilt Σ Gewicht über Land = Zahl der
    // Landzellen: der GESAMTABFLUSS ist exakt der der ungewichteten Akkumulation,
    // der Schalter wirkt als reine UMVERTEILUNG Lee→Luv. Gemessen (n=832,
    // Produktionspfad, Seeds 1337/7/99): `totalOutletArea/Zellzahl` = 1.0000 an
    // wie aus, Landmittel des Gewichts 1.0000, Anteil der Tropfen-Starts auf Land
    // = Anteil der Landzellen auf 4 Stellen (0.3277/0.4560/0.6900) — der
    // Tropfen-Etat auf Land bleibt trotz `hydraulicSkipWaterSpawns` erhalten.
    // Konsequenz: KEIN in Zellen kalibriertes Gate und keine Erosionsrate musste
    // nachgezogen werden (Einzelbelege an den jeweiligen Konstanten unten;
    // Vollmessung: docs/rain-weighted-flow-measurements.md §E/§F).
    //
    // VERWORFEN 1 — rohes `rain` als Gewicht (Stand #9) + Gates/Raten neu
    // kalibrieren. Der nötige Faktor ist das Landmittel des Regens, und das ist
    // weder auflösungs- noch seed-fest: 0.563 (n=192) / 0.398 (n=640) / 0.357
    // (n=832) bei Seed 1337, und bei n=832 allein über die Seeds 0.357 (1337) /
    // 0.544 (7) / 0.488 (99) — `computeRain` trocknet je ZELLE ab, also hängt der
    // Faktor an Auflösung UND Inselgröße. Gegenprobe gemessen: rohes Gewicht mit
    // dem auf Seed 1337 passend gerechneten Render-Gate 114 statt 320 liefert
    // Kanalzellen gegen den ungewichteten Arm (n=832, Jahr 0) −13.6 % (1337),
    // +18.5 % (7), +5.8 % (99) — eine Konstante kann die Inseln nicht gemeinsam
    // bedienen, und die Testkonfigs (n = 96…256) lägen noch einmal woanders.
    // Normiert liegen dieselben drei Seeds bei −6.3 / −3.1 / −6.1 %.
    // VERWORFEN 2 — Normierung auf einen festen Zahlenwert (z. B. 0.40): dieselbe
    // Auflösungs-/Seed-Bindung wie oben, nur unsichtbar gemacht.
    // VERWORFEN 3 — `computeRain` weltmaßstäblich machen (Abtrocknung ∝ cellSize)
    // statt zu normieren: zieht Vegetation, Biom-Färbung und Auwald-Klassen mit
    // (alle lesen `rain` roh) und hätte die Klima-Kalibrierung aufgemacht, ohne
    // die Seed-Abhängigkeit zu lösen. Bleibt als eigenständige Verbesserung offen.
    // Bekannte Kosten der Normierung: das Landmittel ist eine GLOBALE Größe, die
    // je Schritt aus dem Gesamtzustand fällt (es driftet über den Lauf: 0.357 →
    // 0.443 bei n=832/Seed 1337 über 50k Jahre). Genau diese Drift teilt die
    // Normierung heraus — der Gesamtabfluss bleibt über den ganzen Lauf konstant,
    // statt mit der abflachenden Insel um +24 % zu wachsen.
    public var rainWeightedFlow = true
    public var kSed: Double = 1.1e-4   // Erodierbarkeit lockeres Sediment (weicher)
    public var sedCoverThresh: Double = 0.01 // ab so viel Sediment gilt "bedeckt"
    public var transportCap: Double = 9.0  // Transportkapazität-Koeffizient (SPACE)

    // ---- Lithologie: räumlich variable Erodierbarkeit (Issue #12) ----
    // Bis #12 war das Gestein ÜBERALL gleich weich (eine Konstante `kRock` bzw.
    // `outletErode`) — damit sind Schichtstufen, Mesas, strukturkontrollierte
    // Entwässerung und lithologische Knickpunkte strukturell unmöglich. Dieses
    // Feld legt ein deterministisches, seed-abhängiges GESTEINSFELD unter die
    // Landschaft (`Terrain.buildLithologyField` / `Terrain.updateLithology`):
    //
    //     Härte  hard[k] ∈ [−1, +1]  =  (1−Mix)·Schichtwelle + Mix·Provinz + Bias
    //     Erodierbarkeit  K[k] = 1 − lithContrast · hard[k]      (Mittel ≈ 1)
    //     Diffusivität    D[k] = 1 − lithDiffusionContrast · hard[k]
    //
    // Die Schichtwelle ist die STRATIGRAPHISCHE Koordinate s = (h − Schichtebene)
    // / lithLayerThickness, durch ein glattes Wechselprofil geschickt. Weil sie an
    // der aktuellen Höhe hängt, bleibt eine harte Bank auf IHREM Niveau, während
    // die Erosion sie unterschneidet — genau der Mesa-/Schichtstufen-Mechanismus
    // (die Bank wandert nicht mit der Oberfläche mit).
    //
    // WICHTIG — was das Feld liest und was nicht (Kalibrier-Kaskade):
    // * `outletIncision` (die fluviale Makro-Rate der Produktion) skaliert `kOut`
    //   mit K → lithologische Knickpunkte im Talnetz.
    // * `Hydraulic.erode` skaliert den FELS-Anteil jedes Abtrags mit K; das
    //   lockere Sediment darüber erodiert unverändert (Regolith ist Regolith,
    //   egal was darunter liegt). Deshalb braucht der Droplet-Pfad keinen
    //   zweiten Schwellwert.
    // * `hillslopeDiffusion` skaliert kappa mit D → harte Bänke behalten ihre
    //   steile Kante, statt zur Kuppe zu diffundieren (ohne das gibt es keinen
    //   Hangknick, s. Wächter `Lithology.testHardnessContrastHoldsSlopeBreak`).
    // * `transportLimited` (Nicht-Droplet-TESTPFAD) skaliert `kRock` mit K.
    // * NICHT beteiligt: `braidPass`, `wavePass`, `meanderCarve`/-Bankerosion und
    //   die Verlandungs-Pässe — das sind Sediment-/Ufer-/Küstenprozesse in
    //   lockerem Material, nicht Fels-Abtrag. Bewusste Grenze, damit die
    //   Braid-/Mäander-Kalibrierung unangetastet bleibt.
    //
    // GEMESSEN (Wächter `Lithology.swift`, Zahlen und Methode:
    // docs/lithology-measurements.md):
    // * **Hangknick-Signal** = mittlere Makro-Steigung auf hartem gegen weiches
    //   Gestein, lokal gepaart in 16×16-Fenstern, geometrisch gepoolt (n=192,
    //   Seed 1337): AN 0.999 (Jahr 0) → **1.163** (20k J.), Referenzarm
    //   (lithContrast 0) 1.004 → 1.052. Der Knick entsteht also erst über die
    //   Zeit und liegt 11 Punkte über dem Referenzarm.
    // * **Abtragstiefe** hart/weich über 20k Jahre: AN 1.24, Referenzarm 5.03 —
    //   dieselbe Aussage aus der anderen Richtung: ohne Härte trägt genau dort
    //   am meisten ab, wo (zufällig) die harten Provinzen liegen; mit Härte wird
    //   dieses Verhältnis um Faktor 4.4 zurückgedrückt.
    // * **Langzeit-Wächter** (n=160, Seed 1337, 100k J., Produktionspfad):
    //   weichstes Gestein (lithHardBias −1) Relief 0.5363 → 0.3643, maxH 0.6863
    //   → 0.5143 (monoton), See-Anteil 0.053; härtestes (+1) Relief 0.4407, maxH
    //   0.6849 → 0.5907, See-Anteil 0.045. Beide Extreme halten den
    //   LongRunCollapse-Rahmen (Relief > 0.30, See < 0.30, keine wachsenden
    //   Berge); die Alterung selbst bleibt intakt.
    // RÜCKWIRKUNG auf bestehende Wächter (Details: die Kommentare an den
    // gepinnten Stellen und docs/lithology-measurements.md §E): die
    // Mechanik-Wächter von #11 (`EndorheicEvaporation`) und der Braiding-A/B
    // (`testBraidingBuildsBars`) pinnen das Feld AUS — sie prüfen ihre Mechanik an
    // einem konkreten Becken bzw. an einer Seed-Mehrheit, und beides entscheidet
    // die Lithologie mit. Dass die Mechaniken MIT Feld intakt bleiben, ist eigens
    // gemessen (`Lithology.testEndorheicMechanicsSurviveLithology`; Braiding mit
    // Feld: Bank-Fläche 177/106 gegen 132/119 uniform, also stärkerer Kontrast).
    // NICHT gemessen (offener Punkt, s. docs/lithology-measurements.md §F): die
    // Gegenprobe in PRODUKTIONSAUFLÖSUNG (n=832) und über mehrere Seeds. Alle
    // Zahlen hier stammen aus n=160/192/256.
    public var lithologyEnabled = true
    /// Höhen-PERIODE eines Schichtpakets (hart + weich). 0.06 bei einer
    /// Landreliefspanne von ~0.5 = knapp 8 Bänke über den ganzen Hang.
    /// NICHT durchkalibriert (offener Punkt): der Wert kommt aus der Geometrie
    /// (Landreliefspanne / gewünschte Bankzahl), nicht aus einem Sweep. Er ist die
    /// natürliche Stellschraube für „dickbankig gegen feinschichtig"; ein Sweep
    /// 0.03/0.06/0.12 gegen das Hangknick-Signal steht in
    /// docs/lithology-measurements.md §F als offene Messung.
    public var lithLayerThickness: Double = 0.06
    /// Fallen der Schichtebene: Höhenversatz über die ganze Kartenbreite
    /// (Streichrichtung und Betrag variieren je Seed, s. buildLithologyField).
    /// 0 wäre eine horizontale Bank auf gleicher Höhe über die ganze Insel (ein
    /// Terrassen-Ring um jeden Berg — zu regelmäßig); 0.22 verschiebt die
    /// Bankfolge über die Karte um gut 3 Pakete → Cuestas/Schichtkämme mit
    /// wechselnder Höhe. Nicht gesweept (offener Punkt, s. lithLayerThickness).
    public var lithDip: Double = 0.22
    /// Amplitude der Schicht-VERBIEGUNG (Faltung) in Höheneinheiten, fBm über
    /// ~halbe Karte. 0.05 ≈ eine Paketdicke → die Bankfolge wellt sich organisch,
    /// ohne dass die Stapel-Reihenfolge zerfällt (Faltung ≫ Dicke heißt:
    /// benachbarte Zellen liegen in verschiedenen Paketen → Flecken statt Bänke).
    public var lithWarp: Double = 0.05
    /// Anteil des PROVINZ-Rauschens (großräumige Härte-Provinzen ~ halbe Karte,
    /// Batholith gegen Sedimentbecken) am Härtesignal; der Rest ist die
    /// Schichtwelle. 0.35: genug, damit ganze Landstriche härter sind (die
    /// strukturkontrollierte Entwässerung des Tickets), aber die Schichtstufen
    /// bleiben das dominante Signal. 1.0 = reines Noise-Gestein (dann gibt es
    /// keine Stufen), 0.0 = reine Schichtfolge.
    public var lithProvinceMix: Double = 0.35
    /// Erodierbarkeits-Spanne: K = 1 − lithContrast·hard, also K ∈ [0.4, 1.6] bei
    /// 0.6 — Härteverhältnis weich:hart = 4:1. Das Mittel von K bleibt bei 1
    /// (`hard` ist im Mittel ≈ 0), deshalb verschiebt der Kontrast die GLOBALE
    /// Erosionsrate nicht (Härte-Mittel gemessen |mean| < 0.15, Wächter
    /// `testFieldIsDeterministicPerSeed`). Reale Spannen sind größer
    /// (Granit:Schiefer ≈ 1:10); 0.6 ist bewusst konservativ gewählt, weil der
    /// weiche Arm die Erosion beschleunigt und der Relief-Wächter Marge braucht —
    /// gemessen ist der EXTREMFALL (`lithHardBias = −1`, also K ≥ 1.0 auf der
    /// ganzen Karte, bis 1.6 an den weichsten Stellen):
    /// Relief nach 100k Jahren 0.3643 gegen 0.30 Wächterschwelle. Ein Sweep
    /// 0.3/0.9 ist offen (docs/lithology-measurements.md §F).
    /// **lithContrast = 0 ist der REFERENZARM aller Messungen** (Feld wird
    /// gerechnet, wirkt aber nicht → bit-identisch zu lithologyEnabled = false,
    /// Wächter `Lithology.testZeroContrastIsBitIdenticalToDisabled`).
    public var lithContrast: Double = 0.6
    /// Dieselbe Spanne für die HANGDIFFUSIVITÄT (D = 1 − c·hard). Bewusst
    /// SCHWÄCHER als der fluviale Kontrast (0.45 gegen 0.6): das Kriechen hängt
    /// real an Boden/Klima, nicht nur am Fels.
    /// **Ehrliche Messung:** auf den Hangknick hat diese Kopplung KEINEN
    /// messbaren Einfluss — Signal bei 20k mit 0.45 = 1.163, mit 0 = 1.180 (n=192,
    /// Seed 1337, Wächter `Lithology.testDiffusionContrastEffectIsMeasured`, der
    /// genau das festhält). Der Knick kommt aus der fluvialen Rate. Die Kopplung
    /// bleibt, weil sie (a) Abnahmekriterium 2 des Tickets ist und (b)
    /// physikalisch Standard: härteres Gestein liefert weniger Regolith, kriecht
    /// also weniger. Sie ist damit ein Kandidat für eine spätere Kalibrierung,
    /// keine belegte Notwendigkeit.
    public var lithDiffusionContrast: Double = 0.45
    /// Globale Härte-Verschiebung (auf hard addiert, danach auf [−1, 1]
    /// geklemmt). Produktion 0 = die Bandbreite des Seeds. Der Regler existiert,
    /// weil die EXTREME messbar sein müssen: bei `lithHardBias = −1` liegt `hard`
    /// nach der Klemmung überall in [−1, 0], die ganze Karte ist also mindestens so
    /// weich wie das Referenzgestein (K ≥ 1.0, bis 1 + lithContrast an den
    /// weichsten Stellen) — genau der Fall, den Abnahmekriterium 4 verlangt
    /// (Wächter `Lithology.testSoftestRockDoesNotFlatten`). +1 ist die
    /// spiegelbildliche Gegenprobe (K ≤ 1.0, bis 1 − lithContrast).
    public var lithHardBias: Double = 0.0

    // ---- Braiding (Verflechtung: zelluläres Bänke-Bauen, Murray & Paola 1994) ----
    // Die einzige Zutat, die dem MFD-Fundament noch fehlt: SUPER-LINEARER Sediment-
    // Transport. Kapazität je MFD-Route qcᵢ = Kb·Q·Sᵢ·fᵢ^m mit m≈2.5 — die Super-
    // Linearität liegt auf der lateralen PARTITION fᵢ (nicht auf Q·S, das übers Netz
    // 3 Dekaden spannt): ein Faden trägt mehr als zwei halbe (2·0.5^m ≈ 0.35) → Fäden
    // scouren sich ein und ziehen mehr Wasser (positive Rückkopplung), während
    // unterversorgte/aufgespreizte Zellen ablagern → MITTELBÄNKE, um die sich der
    // Lauf teilt und wiedervereint.
    public var braidingEnabled: Bool = true
    // #10: GEPRÜFT, unverändert — das Gate zählt weiter „Zellen", weil der
    // normierte Abfluss dieselbe Skala hat. MFD-Zellen über dem Gate (n=832,
    // Seed 1337, Produktionspfad, aus → an): 27698 → 25805 (Jahr 0, −6.8 %),
    // 35523 → 34638 (5k), 39609 → 38174 (20k), 38569 → 39257 (50k, +1.8 %).
    public var braidMinCells: Double = 120   // Reach-Gate der Braiding-PHYSIK (Render-Schwelle ist separat: renderMinCells)
    // #10: GEPRÜFT, unverändert. Kanalzellen (= Zellen über DIESER Schwelle) in
    // Produktionsauflösung n=832, Produktionspfad, aus → an: Seed 1337 17432 →
    // 16329 / 25555 → 25258 / 28386 → 27184 / 25076 → 27465 (Jahr 0 / 5k / 20k /
    // 50k), Seed 7 −3.1 / −0.6 / −2.9 / −4.0 %, Seed 99 −6.1 / −3.5 / −1.2 /
    // −2.2 % — alles im Band ±10 %, ohne Richtung. Verworfen: die Schwelle auf
    // ~114 zu senken (die #9-Rechnung „Gates sind faktisch 2× zu hoch") — die
    // galt für das UNNORMIERTE Gewicht; mit Normierung würde sie die Zahl der
    // gemalten Läufe um gut die Hälfte anheben (Gate 120 gemessen: 25805 statt
    // 16329 Zellen bei Jahr 0).
    public var renderMinCells: Double = 320  // ab so viel Einzugsgebiet (Zellen) wird ein Lauf GEMALT. Bewusst über dem Physik-Gate (User: „zu viele Flüsse"): Braiding wirkt ab 120 weiter, sichtbar sind nur substanzielle Flüsse. Auf der 832er-Map qualifizieren sich sonst absolut mehr Läufe über dieselbe Schwelle.
    public var braidExponent: Double = 2.5   // Partitions-Exponent m (>1 ist die Bänke-bauende Instabilität)
    public var braidCapacity: Double = 5.0e-6 // Kb: weniger Kapazität lässt überlastete Reaches Bänke ablagern (n=256: Insel-Summe 9 vs. 4 ohne Pass)
    public var braidBarHeight: Double = 0.006 // Bänke dürfen so weit über den Wasserspiegel (hf) wachsen → Inseln
    // Obergrenze der Deposition an NICHT-aktiven Reaches (Delta/Seerand) in
    // `braidPass`, gemessen über dem Wasserspiegel `hf`. Vor Issue #2 stand dort
    // `max(0, hf−h) + 0.005`: das `max` INNEN, der Aufschlag also über dem
    // aktuellen h statt über dem Spiegel — sobald die Schüttung den Spiegel
    // erreicht hatte, durfte JEDER weitere Schritt nochmal 0.005 draufsetzen,
    // der Uferaufbau wuchs also mit der SCHRITTZAHL statt mit der Zeit.
    //
    // 0.05 ist NICHT feinjustiert, sondern ein Wert aus dem gemessenen PLATEAU:
    // im Becken-Testfall (#12-Setup, n=256, Seed 1337, τ=500, 200×20 J.) messen
    // 0.02, 0.06 und 0.15 exakt identisch (größter Spiegelsprung 0.00011, keiner
    // > 0.0015) — dort beschneidet der Deckel die Ablagerung gar nicht mehr, sie
    // endet ohnehin am Sedimentangebot `qin`. Der Deckel kappt also nur den
    // unbegrenzten Schwanz, ohne die Kalibrierung anzufassen. ZU ENG wird es
    // darunter: mit 0.006 (= braidBarHeight) wird der Bilanz-Spiegel der
    // abflusslosen Becken sprunghaft (0.00705, 4 Sprünge), mit 0.02 kippt die
    // Bett-Reconciliation, ohne jede Zugabe die Konfundierung des
    // Hangknick-Referenzarms (1.107 gegen die #12-Schranke 1.08). Die Becken
    // reagieren so empfindlich, weil ihre Hypsometrie flach ist: ein Millimeter
    // Pegel bewegt hunderte Zellen Wasserfläche (gemessen 1319 → 1908 in EINEM
    // Schritt). Vollständige Messtabelle: docs/dt-invariance-measurements.md §2.4.
    public var braidDeltaCeiling: Double = 0.05
    public var braidDispersion: Double = 2.0 // dispersiver MFD-Exponent auf FLACHEN großen subaerischen Läufen (Quinn 1995: Exponent abfluss-abhängig, Terrain.mfdLocalExponent): Hänge konvergieren mit mfdExponent=4 (Look), Braid-Plains spreizen mit 2.0 → Fäden können sich um Bänke teilen, ohne als Sheet-Flow zu zerlaufen (1.3 zerlief)

    // ---- Droplet-Hydraulik-Erosion (carvt feines dendritisches Detail) ----
    public var hydraulicEnabled = true      // Droplet-Erosion statt Grid-Stream-Power+Diffusion
    public var streamRefRate: Double = 0.0025 // Stream-Map-Sättigung (nickmcd): ab dieser reife-gewichteten Tropfen-Besuchsrate (Besuche/Jahr, EWMA) gilt ein Lauf als etabliert (Map ≈ 0.63 bei r0, →1 darüber). Trunk-Raten gemessen ~0.003–0.007/J., Zufallspfade ≪0.001 (reife-gewichtet).
    public var streamMapMemoryYears: Double = 6000 // EWMA-Gedächtnis: bei +2k J. bleibt das etablierte Netz verwandt (Jaccard 0.28 statt 0.20 bei τ=3000), ohne Kurzfrist-Flackern.
    // #10: GEPRÜFT, unverändert. Über See trägt das Gewichtsfeld bewusst den
    // NEUTRALEN Wert 1.0 (= das Landmittel), deshalb landet exakt derselbe Anteil
    // der Tropfen-Starts auf Land wie ungewichtet — gemessen n=832 Jahr 0…50k:
    // Start-Anteil Land = Zell-Anteil Land auf 4 Stellen (0.6900/0.3277/0.4560).
    // Der in #9 §D.3 gemessene Verlust von 21–28 % (rohes Gewicht: über dem Meer
    // regnet es am meisten) ist damit gegenstandslos; die dort erwogene Anhebung
    // der Tropfenzahl ist verworfen (sie wäre land-anteils- und seed-abhängig).
    // Trotzdem gemessen: 2.8 Tropfen/Jahr (×1.4) an n=832/Seed 1337 gegen den
    // Default-Lauf (Jahr 0 / 5k / 20k) — Kanalzellen 16299/25259/27345 (statt
    // 16329/25258/27184, also wirkungslos auf das Kanalnetz), reliefRobust bei
    // 20k 0.1675 statt 0.1714. Reine Zusatz-Erosion ohne Nutzen → verworfen.
    public var hydraulicPerYear = 2.0       // Tropfen je Jahr (sanft → Makro-Grate überleben)
    /// Ozean-Starts sind fast reine Laufzeit-Verschwendung — aber nicht ganz:
    /// nur im TIEFEN Wasser (`hf−h > poolDepth`) stirbt ein solcher Tropfen
    /// wirkungslos im Pool-Zweig, auf dem flachen Schelf läuft er los und
    /// erodiert (sein Pinsel reicht bis auf Küstenzellen). Sie zu verwerfen
    /// ist deshalb NICHT bit-neutral: über das veränderte Abflussfeld erreicht
    /// die Abweichung sofort das Land, es entsteht eine andere (statistisch
    /// gleichwertige) Welt-Realisierung — gemessen und gepinnt in
    /// `SimCoreTests/PerfFlagAB.swift` (Issue #90). Die
    /// Produktionskonfiguration akzeptiert das für die gesparte Laufzeit; der
    /// Core-Default bleibt für bestehende Kalibrierungen unverändert `false`.
    public var hydraulicSkipWaterSpawns = false
    public var outletIncision = true        // Flächen-Stream-Power auf dem Entwässerungsnetz: carvt Täler/Auslässe → Becken entwässern zum Meer, dendritische Rinnen + diskrete Seen (nickmcd-Look) statt einer blassen Flach-Ebene
    // #10: GEPRÜFT, unverändert. Die in #9 §D.2 gerechnete Kompensation (~×1.4
    // gegen den halbierten Abfluss) hat ihre Grundlage verloren: normiert ist der
    // Gesamtabfluss identisch (totalOutletArea/Zellzahl = 1.0000 an wie aus).
    // VERWORFEN, weil trotzdem probiert: outletErode 4.2e-5 (×1.4), n=832,
    // Seed 1337, Produktionspfad, gegen den Default-Lauf (Jahr 0 / 5k / 20k) —
    // Kanalzellen 16293/24043/26283 statt 16329/25258/27184 (der ungewichtete
    // Referenzarm liegt bei 17432/25555/28386, die höhere Rate entfernt sich
    // also), Relief 0.4957 statt 0.4981 bei 20k, Seeanteil 0.0258/0.0728/0.0991
    // statt 0.0261/0.0958/0.1036 gegen 0.0246/0.0774/0.0925 ungewichtet: der
    // Seeanteil kommt bei 5k näher, bei 20k praktisch nicht, und bezahlt wird es
    // mit Kanalzellen und Relief. Für eine Ein-Seed-Beckenstreuung zu teuer.
    // Seeanteil n=832, Produktionspfad, aus → an: Seed 1337 0.0246 → 0.0261
    // (Jahr 0), 0.0774 → 0.0958 (5k), 0.0925 → 0.1036 (20k), 0.0524 → 0.0980
    // (50k); Seeds 7 und 99 haben in BEIDEN Armen praktisch keine Seen
    // (≤ 0.0099). Der 50k-Ausreißer ist ein einzelnes noch nicht durchgeschnittenes
    // Becken (größter See 6698 gegen 45684 Zellen) — dieselbe Einzelereignis-
    // Streuung, die #9 §A schon mit umgekehrtem Vorzeichen gemessen hat (dort lag
    // der AUS-Arm bei 20k höher: 0.1043 gegen 0.0441). Kein systematischer Effekt,
    // also keine Ratenänderung.
    public var outletErode: Double = 3.0e-5 // Rate der Auslass-Inzision. 3e-5 gibt feine dendritische Rinnen „über die ganze Oberfläche" ohne Überkämmen (6e-5 überkarvt bei 100k)
    public var hillDiffusion: Double = 0.012 // Hangdiffusion-Basis (Bodenkriechen, D·∇²z) im Droplet-Pfad, RÄUMLICH VARIABEL (hillslopeDiffusion): rundet soil-mantled/sanfte Hänge, lässt hohen steilen Kahlfels scharf → gerundete Landschaft mit einzelnen spitzen Gipfeln (die Ausnahme). Der fehlende Alterungs-Prozess laut LEM-Recherche (docs/research-terrain-aging.md). Auf n=640 kalibriert (auflösungs-skaliert in step()).
    // ---- Wasserführende Läufe: die EINE Schwelle (Issue #108) ----
    // Drei Pässe müssen wissen, ab wann eine Zelle ein wasserführender LAUF ist
    // und nicht mehr Hang: die Hangdiffusion (kriecht dort weniger ins Bett), die
    // Tropfen-Deposition (der Lauf transportiert durch) und — geparkt, s. unten —
    // die Pfützen-Verlandung. Die Schwelle steht deshalb EINMAL, sonst hängt an
    // drei Stellen dieselbe Kalibrier-Zahl und sie laufen auseinander. Größe = D8-`area` in ZELLEN (Erosions-Netz, nicht
    // MFD — AGENTS.md § Rollentrennung), wie `braidMinCells`/`floodplainMinArea`.
    // Hinweis: „Zellen" meint hier äquivalente Zellen über die #10-Normierung der
    // D8-Akkumulation auf das Landmittel des Regens (Σ über Land = Landzellen · cellArea;
    // gesichert durch den Wächter `testWeightedFlowKeepsDrainageTotal`).
    public var channelFlowMinCells: Double = 320  // ab so viel Einzugsgebiet (Zellen) gilt eine Zelle als wasserführender Lauf. GEMESSEN (n=720, Seed 1337, Quereinschnitt bei 25k in Welt-Y, Kanal-Schutz der Diffusion auf 0.15): 1000 → 0.069, 320 → 0.081, 100 → 0.091, 40 → 0.081. Tiefer zu gehen kauft also fast nichts mehr, kostet aber die ALTERUNG: die mittlere Grat-Krümmung (`ridgeCurvature`, „rund = alt") wächst betragsmäßig von −0.044 (Schutz aus) über −0.058 (320) auf −0.065 (40) — je mehr Netz geschützt ist, desto weniger rundet die Landschaft überhaupt noch. 320 ist der Punkt, an dem der Einschnitt fast voll da und das Alterungs-Signal am wenigsten verschoben ist.
    public var channelFlowFullCells: Double = 3200 // ab so viel Einzugsgebiet gilt „Lauf" voll (smoothstep von MinCells bis hier, damit im Gelände keine Kante entsteht). Faktor 10 Spanne: der Effekt wächst mit der Fluss-Ordnung, statt an einer Kante zu schalten.
    // ---- Kanal-Schutz der Hangdiffusion (Issue #108) ----
    // Bodenkriechen schmiert die Rinnen zu, in denen die Flüsse laufen: die
    // Diffusion sieht eine Rinne als Krümmung und füllt sie, während im aktiven
    // Kanal die Strömung genau dieses einkriechende Material wieder abräumt
    // (Hangfuß-Entfernung — der Grund, warum reale Kerbtäler ihre Form halten).
    // Deshalb wird das lokale kappa auf Zellen mit großem Einzugsgebiet
    // gedrosselt. Größe = D8-`area` in ZELLEN (wie `braidMinCells`,
    // `floodplainMinArea`), Übergang als smoothstep → keine Kante im Gelände.
    // Von den beiden Hebeln dieser Runde ist das der stärkere: er allein hebt
    // den Quereinschnitt (Kennzahl `ChannelIncision`, n=720, Seed 1337) von
    // 0.155 auf 0.306 Welt-Y bei Jahr 0 und von 0.059 auf 0.092 bei 100k.
    // Unterhalb der Schwelle ist der Faktor exakt 1.0 → dort bit-identische
    // Arithmetik (dieselbe Bauform wie der Lithologie-Faktor darunter).
    public var channelDiffusionDamp: Double = 0.15  // kappa-Restanteil im voll geschützten Kanal. 1.0 = Schutz AUS (bit-identisch zum Stand vor #108). 0.0 verworfen: das Bett bekäme gar kein Kriechen mehr, seine Flanken bleiben aber vollständig diffusiv → die Kante Bett/Flanke wird künstlich scharf.
    // ---- Hydraulische Gleichgewichtstiefe des Betts (Issue #108, Ansatz 2) ----
    // Hält das Flussbett im gealterten Gelände auf einer stabilen Zieltiefe
    // unterhalb seiner Talflanken. Kalibriert bei RenderContract.heightScale = 24
    // und riverLift = 0.35 Welt-Y, entsprechend rund 0.0146 Sim-H.
    // Bewusst ein fester Physik-Wert: eine Render-Skalierung darf die Simulation
    // nicht verändern. Bei Änderungen der Darstellung die sichtbare Tiefe neu prüfen.
    // 0 schaltet nur diesen Pass aus, unabhängig von outletIncision.
    // Er gehört wie die Tropfen zum hydraulicEnabled-Zweig.
    // Der Pass läuft nur bei cellSize <= 0.25. Auf gröberen Kalibriergrids ist
    // die Rinne schmaler als eine Zelle; eine ganze Zelle auf diese Render-Tiefe
    // zu schneiden überprägt die Makroform. Gemessen auf n=384: Gletscher-V→U
    // bei 50k b 1.275 gegen 1.296 ohne Eis mit dem Pass, b 1.388 gegen 1.234 ohne.
    // Auf n=160 altert das robuste Relief ohne den groben Schnitt von 0.1260
    // bei 50k auf 0.1074 bei 100k statt bei 0.1050 zu plateauieren.
    public var channelTargetDepth: Double = 0.0146
    // ---- Abfluss-Dämpfer der Tropfen-Deposition (Issue #108) ----
    // Der HAUPTHEBEL gegen „Flussbett auf Umgebungsniveau": ein wasserführender
    // Lauf transportiert Fracht durch, statt sein eigenes Bett zu verfüllen.
    // Herleitung, Kennzahl und Messwerte stehen bei `Terrain.buildDepositDamp`;
    // der Präzedenzfall mit MÄANDER-Maske ist `HydraulicParams.channelDepositDamp`.
    // Größe = D8-`area` in ZELLEN (Erosions-Netz, nicht MFD), Übergang smoothstep.
    public var flowDepositDamp: Double = 0.15   // Depositions-Restanteil im voll wasserführenden Lauf. 1.0 = Dämpfer AUS (bit-identisch zum Stand vor #108). GEMESSEN (n=720, Seed 1337, Quereinschnitt in Welt-Y bei Jahr 0 / 100k, Kanal-Schutz der Diffusion an): 1.0 → 0.306/0.092, 0.30 → 0.429/0.076, 0.15 → 0.458/0.086, 0.05 → 0.502/0.082. Unter 0.15 kauft der Dämpfer nur noch den frischen Zustand, nicht mehr das Alter — und 0.0 ist am Präzedenzfall als instabil belegt (der Tropfen dumpt seine Gesamtlast am ersten Hindernis → Halden, Relief-Runaway). 0.15 hält denselben Abstand zu dieser Kante wie `channelDepositDamp`.
    // ---- Pfützen-Ausschluss in Flussbetten (Issue #108) — GEPARKT ----
    // Der DRITTE Hebel, gemessen der stärkste und trotzdem AUS. `fillShallowPonds`
    // ist ein Aufräum-Pass gegen Flachwasser-Sprenkel in reifen Auen; im FLUSSBETT
    // schüttet er mit `puddleFillDepth` (0.06 = 1.4 Welt-Y) und τ =
    // `puddleFillYears` genau die Rinne zu, um die es hier geht. Die
    // Mäander-Betten (`isChannel`) nimmt er längst aus; der Schalter ist dieselbe
    // Regel für die dendritischen Läufe, die keine Maske haben.
    // GEMESSEN (n=720, Seed 1337, Quereinschnitt bei 100k, mit beiden anderen
    // Hebeln): 0.086 → 0.158 Welt-Y, fast eine Verdopplung.
    // WARUM TROTZDEM AUS: die Pfützen im Bett BLEIBEN dann stehen, und stehendes
    // Wasser im Bett ist genau die Sorte Wassersäule, an der die Render-Übergabe
    // Band ↔ Raster hängt (`WaterRender.lakeRawWetDepth`). Gemessen sprang die
    // Doppelmalungs-Kennzahl von `WaterRendererTests
    // .testBuiltBandsAndRasterHandOverWithoutGapOrDoubleWater` von 0.024 auf
    // 0.243 (heutige Schranke 0.045), und die dt-Invarianz des Seeanteils riss ebenfalls
    // (`DtInvariance`: dt 10 gegen 2000, 0.0040 gegen 0.107). Der Hebel taugt
    // also, aber erst zusammen mit einem Pass, der die Pits im Bett
    // ENTWÄSSERT statt sie nur nicht mehr zu füllen — offener Punkt in
    // `docs/channel-incision-measurements.md` §E.
    public var puddleFillSkipsFlowCells = false
    // ---- Auen/Schwemmebenen (Überflutungs-Aggradation) ----
    // Flüsse lagern seitlich Sediment ab und bauen flache Auenböden — die breiten
    // Niedrig-Gradient-Reaches, in denen sie mäandern/verflechten können. Ohne sie
    // sind die Talböden zu schmal (V-Täler) für sichtbare Fluss-Dynamik. Füllt nur
    // tal-nahe Zellen bis knapp über Bett-Niveau → steile Talwände bleiben unberührt
    // (die Berge werden NICHT zugeschüttet). Physisch = Overbank-Deposition.
    public var floodplainEnabled = false // AUS: die per-Zell-Aggradation fügt feine Krusten hinzu (gemessen 2.7× Zerklüftung bei 3000 J.) für unbestätigten Auen-Nutzen → zurückgenommen. Seit Issue #174 entsteht die Aue stattdessen aus der lateralen Planation des Mäandergürtels (`meanderBelt`: Gleithang-Bank gedeckelt auf bankfull, gemessen GLATTER als vorher, `docs/zielbild-measurements.md` § Paket B). Code bleibt als Referenz.
    // #10: unverändert (Pass ist ohnehin aus) — dieselbe Begründung wie bei
    // braidMinCells: der normierte Abfluss zählt weiter in Zellen.
    public var floodplainMinArea: Double = 500  // ab so viel Einzugsgebiet (Zellen): NUR Hauptflüsse bauen Auen. Niedrig (60) → jedes Rinnsal baut Levees → Krusten-Rauschen (verworfen). Bergbäche haben real keine Aue.
    public var floodplainMaxElev: Double = 0.50 // NUR Tiefland-Reaches (Kanalbett unter dieser Höhe) bauen Auen — Schwemmebenen sind Tiefland-Features, nicht am Berg.
    public var floodplainDepth: Double = 0.016  // Bett+Auenhöhe (bankfull): bis hierher wird tal-nah aufgefüllt (kleine Flüsse)
    public var floodplainDepthK: Double = 0.020 // zusätzliche Auenhöhe ∝ log(Abfluss) → große Flüsse breitere/höhere Auen
    public var floodplainWidthK: Double = 1.8   // Auen-Halbbreite (Zellen) ∝ floodplainWidthK·log(Abfluss)
    public var floodplainFillYears: Double = 2500 // Zeitkonstante der Auen-Aggradation

    // ---- Becken-Entwässerung bei der Generierung (antezedente Täler) ----
    // Die Makro-Generierung erzeugt Insel-Formen mit geschlossenen Becken, die
    // vollaufen (ein Zentralsee verdeckt genau die flachen Auen, in denen Mäander/
    // Braiding sichtbar wären). Vorbild nickmcd: diskrete Seen auf verschiedenen
    // Ebenen, die ineinander und ZUM MEER entwässern. Der Spin-up lässt die
    // Auslass-Inzision (dasselbe getestete outletIncision wie im Sim-Loop) die
    // Becken-Sillen VOR Spielbeginn durchschneiden — physisch: antezedente Täler,
    // die Entwässerung ist älter als die sichtbare Landschaft.
    public var breachEnabled = true
    public var breachMaxRounds = 30          // Spin-up-Deckel (Runden à breachDT)
    public var breachDT: Double = 6000       // Jahre Auslass-Inzision je Runde
    public var breachTargetLakeFrac = 0.05   // Ziel: See-Anteil am Land < 5% → Stopp
    public var basinFill = false            // AUS seit die Hebung niedrig ist (0.0015): Auslass-Inzision + wenig Hebung halten den See-Anteil schon von allein bei ~15% als DISKRETE blaue Seen. basinFill würde sie zu ~1% überfüllen → blasse, trockene Flach-Ebenen (die das Stream-Overlay weiß übermalt). Nur bei hoher Hebung nötig.
    public var puddleFillDepth = 0.06       // NUR seichtes Ponding verlandet (anders als basinFill): geflutete Auen trugen sonst dauerhafte Flachwasser-Sprenkel („Blob-Fetzen", total unrealistisch). Echte Seen sind tiefer und bleiben.
    // Zeitkonstante der Pfützen-Verlandung (0 = aus). Seit Issue #2 EXPONENTIELL
    // gelesen (`1 − e^(−dt/τ)` statt `min(0.5, dt/τ)`) — der Wert selbst ist
    // unverändert, aber er bedeutet jetzt wirklich eine Zeitkonstante: der
    // Anteil, der in dt verlandet, teleskopiert über beliebig viele Teilschritte.
    // Die alte lineare Form war ab dt = 400 J. am 0.5-Deckel und ließ große
    // Schritte systematisch zu viel Ponding stehen (dt = 2000: 0.5 statt der
    // korrekten 0.918). Gemessen an der Pfützen-Bilanz über 20k Jahre
    // (n=192, Seed 1337): verlandetes Volumen 205 (dt=240) gegen 18 (dt=2000) —
    // der Rest der Lücke ist die Operator-Splitting-Drift des Tropfen-Passes,
    // s. docs/dt-invariance-measurements.md.
    public var puddleFillYears = 800.0
    public var puddleLakeCoreCells = 48     // See-Kern-Schwelle der Pfützen-Verlandung (s. fillShallowPonds): eine Wasser-Komponente mit ≥ so vielen TIEFEN Zellen (Tiefe > puddleFillDepth) ist ein SEE — ihr Ufersaum verlandet nicht mehr pauschal (die Säume hoben sich sonst als Ganzes sichtbar an: „wachsender Boden ohne Wasser", 90% der Tiefland-Hebung), sondern nur physisch über Droplet-Deltas. Braid-/Auen-Pfützennetze (Einzelpools ≪ 48 tiefe Zellen) verlanden unverändert — Komponentengrößen-Schwellen (64/400 Zellen) und „berührt einen Pool" kippten dagegen den Braid-Insel-Guard, ein relativer Kern-Anteil (20%) ließ den Problemfall (riesiger Saum, kompakter Kern) durch.
    // ---- Verdunstung in abflusslosen Becken (endorheische Seen, Issue #11) ----
    // Der Priority-Flood füllt jedes geschlossene Becken bis zur SILL, ohne
    // Zufluss oder Verdunstung zu kennen — endorheische Becken, Playas und
    // Salzseen sind damit strukturell unmöglich (die bewusste Abweichung von der
    // nickmcd-Referenz, docs/nickmcd-behavior-verification.md). Dieser Schalter
    // legt einen einfachen Wasserhaushalt je Becken darüber
    // (`Terrain.capEndorheicBasins`):
    //
    //     Zufluss (Abfluss des Beckens)  gegen  Verdunstung über der Seefläche
    //     A_zu  ≥  κ · Σ_Seezellen cellArea · aridity(k)
    //
    // Der Zufluss ist der niederschlagsgewichtete Abfluss aus #9/#10 (deshalb
    // hängt #11 daran): `area` trägt seit #10 ABFLUSS statt Fläche, normiert auf
    // das Regen-Landmittel. Genau diese Normierung macht κ interpretierbar:
    //
    //     κ = potenzielle Seeverdunstung / mittlere Abflusshöhe des Landes
    //
    // — das dimensionslose Verhältnis, das in der Seehydrologie als nötiges
    // EINZUGSGEBIET-ZU-SEEFLÄCHE-Verhältnis eines abflusslosen Sees auftritt
    // (Großer Salzsee ≈ 9:1, Kaspisches Meer ≈ 10:1, Tschadsee ≈ 100:1 in extrem
    // arider Lage; humide geschlossene Seen liegen bei wenigen Einheiten).
    //
    // WICHTIG — κ IST der Klima-Regler dieses Modells: weil #10 den Abfluss auf
    // sein Landmittel NORMIERT, fällt die absolute Nässe des Klimas aus `area`
    // heraus (ein global doppelt so feuchtes Klima liefert dasselbe
    // `rainWeight`). „Feucht" vs. „trocken" ist deshalb ein kleines vs. großes κ,
    // und der Wächter `EndorheicEvaporation.testWetAndDryClimateDifferBasinLevel`
    // fährt genau das (dasselbe Becken, κ feucht/trocken).
    public var endorheicEvaporation = true
    // κ. ZUERST GEMESSEN, was die Landschaft überhaupt für Verhältnisse hat
    // (`EndorheicEvaporation.testBasinRatioMeasurementDiagnostic`, n=256, Zufluss
    // in Zellen je Seezelle = genau das Verhältnis, gegen das κ antritt):
    // die GROSSEN Becken liegen bei 1.7 … 5.1 (Seed 1337: 2194 Z → 3.02 bei der
    // Generierung, 5172 Z → 1.74 bei 10k; Seed 42: 743 Z → 4.79; Seed 2024:
    // 555/326/243 Z → 5.02/3.47/2.91), die kleinen Pools bei 10 … 400 — sie
    // liegen IM Flusslauf und bekommen den ganzen Trunk-Abfluss.
    // Daraus folgt die Kalibrierung: κ trennt nicht „groß gegen klein", sondern
    // „überfüllt gegen gespeist", und der interessante Bereich ist einstellig.
    // Sweep in PRODUKTIONSAUFLÖSUNG (n=832, Seed 1337, Produktionspfad; See-
    // Anteil am Land / davon sichtbar (Tiefe > 0.03) / Zahl der verdunstungs-
    // limitierten Becken / Salzpfannen-Zellen, bei Jahr 0 und 20k):
    //   κ=0 (aus)  J0 4.99/2.61/0/0      J20k 13.89/10.36/0/0
    //   κ=1.0      J0 4.99/2.61/4/0      J20k 13.28/ 9.66/1/3495
    //   κ=1.25     J0 4.99/2.61/9/0      J20k 13.33/10.04/2/3625
    //   κ=1.5      J0 4.88/2.77/12/0     J5k   2.43/ 0.51/9/44211   ← kippt
    //   κ=2.0      J0 4.55/2.06/21/0     J5k   0.85/ 0.00/10/55154  ← kippt
    //   κ=3.0      J0 2.68/0.81/27/0     J5k   0.76/ 0.00/15/54590
    // GEWÄHLT κ=1.25. Der Sprung zwischen 1.25 und 1.5 ist keine Willkür der
    // Kalibrierung, sondern die gemessene RATIO-VERTEILUNG dieser Landschaft: die
    // tiefen Becken liegen dicht über 1 (1.63 / 1.93 / 2.2 bei n=832, 20429 /
    // 39996 / 24863 Zellen), die flachen Fluss-Pools bei 5 … 800. Ab κ=1.5 kippen
    // ALLE tiefen Becken gleichzeitig — Seeanteil 13.9 → 2.4 %, sichtbare
    // Seefläche 10.4 → 0.5 %, ein Viertel des Landes Salzpfanne. Das wäre nicht
    // „endorheische Becken sind möglich", sondern „es gibt keine Seen mehr", und
    // widerspricht dem Ziel-Look (ROADMAP: diskrete blaue Seen auf verschiedenen
    // Ebenen, nickmcd-Referenz).
    // κ=1.25 trifft genau die überfüllten Becken (Ratio < 1.25) und lässt die
    // gespeisten stehen: sichtbare Seefläche 10.04 gegen 10.36 % (−3 %), dabei 2
    // abflusslose Becken mit 3625 Salzpfannen-Zellen (~1 % des Landes).
    // Physisch ist κ = Seeverdunstung / mittlere Abflusshöhe, also
    // (E − P)/(P · Abflussbeiwert) + 1: κ=1.25 heißt E ≈ 1.08 · P bei einem
    // Abflussbeiwert von 0.3 — die feuchte, kühle Insel, die dieses Terrain
    // darstellt. κ=2 wäre das semi-aride Ende (E ≈ 1.3 · P), κ ≤ 1 die
    // Verdunstungs-freie Grenze: unter 0.75 ist der Pass auf diesem Terrain
    // messbar ein NO-OP (n=256: bit-identisch zum abgeschalteten Feature,
    // Wächter `testUncappedRunIsBitIdenticalToDisabled`).
    // κ IST DER KLIMA-REGLER: für eine trockene Welt hochdrehen — die
    // Mechanik-Wächter fahren bewusst κ=6 (`dryCfg()` in
    // `EndorheicEvaporation`), damit sie an der Produktions-Kalibrierung nicht
    // hängen.
    // Relief bleibt über den ganzen Sweep im Band (n=832: 0.1831 aus → 0.1704 bei
    // κ=1.25, −7 %), der LongRunCollapse-Wächter (0.30 bei n=160) behält Marge.
    // MESS-STAND: die J5k/J20k-Zeilen sind VOR dem Zufluss-Fix in
    // `floodAndRoute` entstanden (Becken-Rollen werden jetzt vor der
    // Zufluss-Messung gelöscht, s. dort). Der Fix erhöht den gemessenen Zufluss,
    // deckelt also WENIGER — die Auswahl von κ=1.25 liegt damit auf der sicheren
    // Seite; die Jahr-0-Zeilen sind unberührt (bei der Generierung startet die
    // Maske ohnehin leer). Nachmessen der Spätphase: offener Punkt in
    // docs/endorheic-evaporation-measurements.md.
    public var endorheicEvapRatio: Double = 1.25
    // Klima-Kopplung der Verdunstung: aridity(k) = 1 + a·(1 − rainWeight[k]),
    // gedeckelt auf [0.25, 4]. `rainWeight` ist der auf 1 normierte Regen (#10),
    // also verdunstet der Regenschatten-Osten mehr als die Luvseite — dieselbe
    // Orographie, die den Zufluss verteilt, verteilt auch die Verdunstung, nur
    // mit umgekehrtem Vorzeichen. a=0.5: bei gemessener Gewichtsspanne 0.35…2.9
    // liegt der Faktor real zwischen 0.75 (nasses Luv) und 1.33 (Lee).
    // a=0 = klima-neutrale Verdunstung (Referenzarm der Messung: Wächter
    // `testAridityLowersTheLeewardBasin` vergleicht a=0 gegen a=0.5).
    public var endorheicAridity: Double = 0.5
    // Becken kleiner als das werden nicht bilanziert (Rest-Pfützen einzelner
    // Zellen). Bewusst KLEIN: das Größen-Gate ist nur ein Rechen-/Rausch-Deckel,
    // die eigentliche Auswahl trifft die Bilanz selbst (eine Pfütze IM Flusslauf
    // hat den ganzen Trunk-Abfluss als Zufluss und bleibt deshalb voll, egal wie
    // klein sie ist).
    public var endorheicMinBasinCells: Int = 12
    // Ratenbegrenzung des Bilanz-Spiegels (Zeitkonstante, 0 = instantan). Der
    // Zielstand springt, wenn ein Becken kippt (Sill zugeschüttet → andere
    // Seefläche → anderes Budget); ohne Begrenzung flackerte der Spiegel dieses
    // Beckens zwischen Sill und Bilanzstand. 500 J.: doppelt so träge wie der
    // DARSTELLUNGS-Spiegel (lakeLevelResponseYears 250) — der bleibt in Serie
    // dahinter und dämpft den Rest (Wächter: LakeLevelStability,
    // EndorheicEvaporation.testBasinLevelIsRateLimited). Physisch ist das die
    // Füll-/Leerzeit eines Sees; geologisch kurz, aber der Spielmaßstab sind
    // 10k-Jahre-Sprünge.
    public var endorheicResponseYears: Double = 500.0
    // Salzkruste/Playa: Aufbau-/Abbau-Zeitkonstante des Verdunstungsrückstands
    // auf trockengefallenem Beckenboden (Terrain.saltCrust, 0 = aus). NUR
    // Rendering (helle Kruste in SimRender.TerrainColorRenderer) und
    // Vegetations-Ziel (Salzpfannen sind kahl) — keine Erosionsphysik. 400 J.:
    // die Kruste liegt nach ~1200 J. voll da, verschwindet aber nach dem
    // Wiederfluten in derselben Zeit wieder (kein Geister-Weiß in einem vollen
    // See).
    public var endorheicSaltYears: Double = 400.0
    // Mindest-Vollstand-Tiefe, ab der ein trockengefallener Beckenboden als
    // SALZPFANNE gilt (Terrain.playaBed). 0.03 = die Render-Seetiefe (dieselbe
    // Schwelle wie vegFloodKillDepth und HydraulicParams.poolDepth:
    // „substanzielles stehendes Wasser"). Nötig, weil der Priority-Flood den
    // ganzen flachen Beckenboden flutet: von den 9788 trockengefallenen Zellen
    // des Seed-1337-Beckens (n=256, 10k J.) stand auf der großen Mehrheit nie
    // mehr als ein Millimeter Wasser — als Salzweiß gemalt wäre das die halbe
    // Insel, statt der Pfanne im Beckenkern.
    public var endorheicSaltMinDepth: Double = 0.03
    public var lakeLevelResponseYears = 350.0 // Zeitkonstante des DARSTELLUNGS-Seespiegels (Terrain.waterLevel; 0 = aus, Spiegel = hf). Priority-Flood hebt hf beim Zuschütten des Auslass-Sills INSTANTAN fürs ganze Becken; die Auslass-Inzision schneidet in ~100 J. zurück → Sägezahn, sichtbar als periodisch hüpfende See-/Schwemmflächen (gemessen n=832 Seed 1337, 3000 J.: 17 hf-Sprünge > 0.0005, max 0.006; Quellen Droplets+Braiding+Mäander gemeinsam, Dämpfung einzelner Depositionspfade griff nicht und verschob nur die Kalibrierung). 250 J. drückt die sichtbare Restamplitude der ~100-J.-Sägezähne auf ~1/6 (gemessen via LakeLevelStability), lässt echte Pegeländerungen (Verlanden, neue Seen, +10.000-J.-Sprünge) aber praktisch ungebremst durch. 250 → 350 mit dem Umstieg auf 720/112,4789: die kleinere Welt schüttet ihren Auslass-Sill in 1,59× größeren Stufen zu (hf-Sprung 0,00755 → 0,01198 gemessen, Seed 1337, größtes Becken), und der gedämpfte REST stieg damit von 0,00067 auf 0,00181 — über die Sichtbarkeitsschwelle 0,0015, die LakeLevelStability prüft. Die Dämpfung selbst war intakt (1/6,6, die Zusage ist ~1/6; 832 lag mit 1/11 nur besser als versprochen). 350 stellt die Reserve wieder her (350 und 400 beide grün, 350 als kleinere Änderung gewählt); der Preis ist ein träger reagierender Darstellungsspiegel, echte Pegeländerungen bleiben ungebremst. Seit Issue #174 wirkt die Zeitkonstante nur auf den ANSTIEG: fällt hf, folgt der Spiegel sofort (Geister-Seen auf dem frisch gegrabenen Mäandergürtel, s. `Terrain.relaxWaterLevel`).
    public var hydraulic: HydraulicParams = {
        var h = HydraulicParams()
        h.inertia = 0.10 // mehr Trägheit → längere, verzweigende (dendritische) Rinnen
        return h
    }()

    // Hangprozesse laufen über LINEARE Diffusion (hillDiffusion oben, im
    // Nicht-Droplet-Testpfad diffusionPass) — die Schwellen-Talus-Variante
    // (`thermalPass` mit talus/thermalRelax/rockCrumble) ist entfernt: sie
    // erzeugte planare Facetten statt konvexer Kuppen und war seit dem Wechsel
    // auf lineare Diffusion nirgends mehr aufgerufen (s. ROADMAP „Toter Code").
    // Küsten-Talus ist davon unberührt (waveTalus, wavePass).

    // ---- Relief-Servo — seit Issue #13 nur noch UNTERGRENZE ----
    // Der Servo hebt nach, wenn das Relief-Signal unter reliefTarget fällt,
    // proportional zum Defizit (∝ deficit/reliefServoBand, gedeckelt bei
    // reliefServoPer100y), entlang des fixen ridged-Tektonik-Felds (dieselben
    // Gebirge wachsen nach, keine neuen), nur über dessen POSITIVEN Teil und nur
    // auf Land.
    //
    // ROLLENWECHSEL (Issue #13): Er war der Haupt-Hebungsmechanismus und hat damit
    // die Alterung VERHINDERT — auf reliefTarget = 0.20 geregelt lief er dauerhaft
    // (Signal real 0.09–0.18) und immer stärker, je flacher das Terrain wurde.
    // Gemessen (n=160, Seed 1337, 100k, alle 20k): Relief fiel nur bis 30k
    // (0.5335 → 0.4569) und wurde danach WIEDER HOCHGEREGELT (→ 0.5097), die
    // Gratkrümmung blieb ab 10k flach bei ≈ −0.030. Genau das „ewig junge
    // Gleichgewicht" aus dem Ticket. Die Alterung trägt jetzt die abklingende
    // Hebung U(t) (s. oben); der Servo ist nur noch der NOTBODEN gegen echtes
    // Einebnen.
    //
    // reliefTarget deshalb von 0.20 auf 0.05 GESENKT. Gemessener Anteil der
    // Schritte, in denen der Servo überhaupt anspringt (Produktionspfad,
    // n=160, Seed 1337, 200k Jahre): reliefTarget 0.20 → **1.000** (jeder
    // Schritt, Relief endet bei 0.4961 statt 0.3359 = die Alterung ist gelöscht),
    // 0.09 → 0.000, 0.07 → 0.000. Untergrenze gewählt aus dem MULTI-SEED-Minimum
    // des Signals über 100k Jahre: 0.0962 (1337) / 0.1079 (7) / 0.0684 (99) /
    // 0.0859 (2024) / 0.1255 (555). 0.07 läge über dem Minimum von Seed 99 — der
    // Servo würde dort mitten in der normalen Alterung anspringen. 0.05 hält
    // ~27 % Abstand unter das gemessene Minimum aller Seeds und fängt trotzdem
    // eine echte Peneplanation (Signal → 0) ab.
    //
    // REGELSIGNAL ist `Terrain.landReliefRobust()` = **95. Perzentil − Median der
    // Landhöhen** (war: `landRelief()` = max − min über Land). Grund: max − min
    // hing an zwei Extremzellen — das Minimum liegt per Definition knapp über
    // `sea`, das Signal WAR also die Höhe der höchsten Zelle und steuerte damit
    // die Hebung von ~480k Landzellen. Messung (n=160, Seed 1337, 100k Jahre
    // gealtert): eine einzige auf 1.4 gezogene Zelle verschiebt max − min von
    // 0.5097 auf 1.2500 (+145 %), das Perzentil-Signal überhaupt nicht
    // (0.16211 → 0.16211; exakt sortiert gerechnet +0.019 %, 0.161965 →
    // 0.161995 — weniger als die Bin-Breite 0.000488 der Histogramm-Auswertung
    // in `landReliefRobust`) — genau der Hebel, den ein Sculpt-Strich heute
    // auslösen konnte (sculpt koppelt zusätzlich in upliftBase).
    // Verworfene Alternative „mittleres lokales Relief im Fenster": auflösungs-
    // abhängig, gemessen auf frischem Terrain (Seed 1337) ±1 Zelle: 0.113 (n=80)
    // → 0.079 (160) → 0.051 (320) → 0.035 (640); auch mit weltfestem Fenster
    // (±0.8 Welteinheiten) noch 0.113/0.079/0.092/0.106. Das Perzentil-Signal
    // liegt dagegen bei 0.165 / 0.178 / 0.183 / 0.185 / 0.185 (n = 80 / 160 /
    // 320 / 640 / 832 = Produktion) — praktisch auflösungsfrei (Spanne 11 %,
    // ab n=160 nur noch 3.7 %), d. h. Testkonfigs mit kleinerem n regeln auf
    // dasselbe Ziel wie die Produktion. Wächter: `ReliefSignal
    // .testSignalIsResolutionStable` misst dieselbe Reihe bis n=832.
    //
    // ---- HISTORISCH (Herleitung des alten Ziels 0.20, gültig bis Issue #13) ----
    // reliefTarget umgerechnet: 0.55 (max − min) → 0.20. Umgerechnet wird über die
    // gemessene SENSITIVITÄT, nicht über das Niveau-Verhältnis: das robuste Signal
    // liegt zwar nur bei ~0.30 × (max − min), ändert sich aber fast parallel dazu
    // (der Median der Landhöhen bleibt über den Lauf nahezu konstant). Steigung
    // aus der ALTEN Trajektorie (Zeile „alt" unten, Servo noch auf max − min,
    // n=160, Seed 1337): 10k → 30k fällt max − min um 0.0414 (0.4960 → 0.4546),
    // das robuste Signal um 0.0290 (0.1600 → 0.1310) ⇒ Steigung 0.70. Damit wird
    // die alte, hart codierte Defizit-Spanne 0.1 zu reliefServoBand = 0.07, und
    // aus dem Servo-Anteil am Betriebspunkt (10k: 0.54) folgt reliefTarget =
    // 0.16 + 0.54·0.07 ≈ 0.20. Kontrolle über den ganzen Lauf (Anteil alt → neu):
    // 10k 0.54→0.57, 20k 0.78→0.83, 30k 0.95→0.99, 100k 0.55→0.62 — der Servo
    // arbeitet am selben Betriebspunkt, minimal fester.
    // Verworfen: reliefTarget 0.17 / Band 0.03 (aus dem NIVEAU-Verhältnis 0.30
    // statt aus der Sensitivität gerechnet). Der Servo lief damit in der Frühphase
    // zu schwach — Anteil 0.23 statt 0.54 bei 10k, Plateau-Relief 0.491 statt
    // 0.495 (max − min).
    // Gemessene 100k-Trajektorien (n=160, Seed 1337, alle 10k Jahre):
    //   max − min   alt 0.533 0.496 0.472 0.455 0.468 0.480 0.482 0.488 0.491 0.495 0.495
    //               neu 0.533 0.495 0.467 0.457 0.476 0.491 0.497 0.504 0.509 0.511 0.510
    //   robust      alt 0.178 0.160 0.142 0.131 0.130 0.134 0.140 0.146 0.151 0.154 0.157
    //               neu 0.178 0.155 0.140 0.131 0.130 0.139 0.146 0.153 0.157 0.159 0.162
    // (robuste Werte auf 3 Stellen gerundet; die Kennzahl selbst ist auf Vielfache
    // von 0.000488 quantisiert — s. `Terrain.landReliefRobust`.)
    // Dieselbe Delle bei 30k, dasselbe Plateau (neu ~3 % höher) — das Relief läuft
    // weder weg noch ebnet es ein.
    // ---- Ende HISTORISCH ----
    public var reliefTarget: Double = 0.05
    public var reliefServoPer100y: Double = 0.0015
    /// Defizit-Spanne, über die der Servo von 0 auf reliefServoPer100y hochfährt
    /// (früher hart codierte 0.1 auf max − min; s. Umrechnung bei reliefTarget).
    public var reliefServoBand: Double = 0.07

    // ---- Abklingende Hebung (post-orogener Zerfall) — DER Alterungs-Mechanismus ----
    //
    //     U(t) = U_floor + (U₀ − U_floor) · e^(−t/τ)
    //
    // Baldwin/Whipple/Tucker 2003 über docs/research-terrain-aging.md §3: ein
    // stationäres Gleichgewicht (konstantes U) altert NIE — es bleibt „ewig jung".
    // Erst wenn die Tektonik abschaltet, zerfällt das Relief, während die
    // (weiterlaufende) lineare Hangdiffusion die Grate rundet: „jung spitz → alt
    // rund". `step()` integriert U(t) über den Zeitschritt geschlossen
    // (`Terrain.upliftDecayAmount`) — Zeitraffer und +10.000-Jahre-Sprung tragen
    // exakt dieselbe Hebung ein.
    //
    // ENTSCHEIDUNG „Orogenese-Höhepunkt vs. U₀ mit Erosion-überwiegt" (Issue #13):
    // **Start am Orogenese-Höhepunkt.** Die Generierung liefert den fertigen,
    // scharfen Gebirgszustand (ridged Multifraktal + Pre-Erosion, `generate`), es
    // gibt keine Aufbauphase — U(t) klingt ab t=0 ab, U₀ ist der REST der
    // Orogenese, kein Anschub. Damit gibt es per Konstruktion keinen
    // Wachstums-Puls. Gegenprobe gemessen (n=160, Seed 1337, 100k):
    //   U₀ = 0.006 → maxH 0.6836 → 0.7647 (Peak 0.7805), meanLand +18 % — die
    //     Berge WACHSEN, verworfen.
    //   U₀ = 0.003 → maxH endet mit 0.6739 zwar unter dem Start, dreht ab 20k aber
    //     wieder hoch (0.6484 → 0.6831) — verworfen.
    //   U₀ = 0.0008 (gewählt) → maxH über alle 5 gemessenen Seeds MONOTON fallend,
    //     Spitzenwert des Laufs = Startwert (Multi-Seed-Tabelle unten).
    //
    // U₀ = 0.0008: das ist gut die Hälfte des alten Servo-Deckels (0.0015) und
    // damit klein genug, dass die Erosion ab dem ersten Schritt überwiegt.
    // Verworfen (alle n=160, Seed 1337, Servo aus, relief/ridgeCurv bei 100k;
    // ridgeCurv = `Terrain.ridgeCurvature()`, negativ = spitz, gegen 0 = rund):
    //   U₀ 0.0015 → relief 0.4336, curv −0.0279, See-Anteil 0.029 (bei 200k 0.002):
    //     altert zu langsam UND die Auslass-Inzision räumt bei dem Gefälle jedes
    //     Becken frei → die diskreten Seen des Ziel-Looks verschwinden.
    //   U₀ 0.0012 → relief 0.4181, curv −0.0253, See-Anteil 0.033 — dasselbe milder.
    //   U₀ 0.0004 → relief 0.3647, curv −0.0212, aber der Sockel trägt nicht mehr
    //     (200k: relief 0.3135 gegen 0.3359 bei 0.0008).
    // Gewählt U₀ 0.0008 → relief 0.3883, curv −0.0219, See-Anteil 0.052.
    //
    // U_floor = 0.1·U₀ (Rest-Tektonik, Recherche-Empfehlung 0.05–0.1·U₀): hält den
    // „Appalachen-Sockel". Ohne Floor (U ≡ 0) fällt das Relief über 200k auf 0.2680
    // — UNTER die Einebnungs-Schwelle 0.30 des LongRunCollapse-Wächters; mit Floor
    // 0.3359 (+25 %). Im 100k-Fenster ist der Unterschied noch klein (0.3509 gegen
    // 0.3883), der Floor zahlt sich erst in der Spätphase aus — genau seine Rolle.
    //
    // τ = 40000 Jahre = Mitte des Recherche-Bands 30k–60k. Bei 100k Jahren (2.5 τ)
    // ist U(t) auf 8 % von U₀ abgefallen, der Zerfall also innerhalb des
    // Spiel-Fensters praktisch abgeschlossen. Gemessen bei 100k (relief / curv /
    // See-Anteil): τ=30k → 0.3817 / −0.0215 / 0.032 · τ=40k → 0.3883 / −0.0219 /
    // 0.052 · τ=60k (floor 0) → 0.3994 / −0.0238 / 0.036. Die Alterung ist über das
    // Band robust; 40k hält die Seen am besten.
    //
    // ALTERUNGSVERLAUF, Produktionspfad n=160, Seed 1337, alle 20k Jahre
    // (Belegtabellen und die Vergleichsarme: docs/terrain-aging-measurements.md):
    //   relief     0.5335 0.4706 0.4252 0.4138 0.4016 0.3883  (0 … 100k, −27 %)
    //   ridgeCurv −0.0453 −0.0290 −0.0253 −0.0225 −0.0226 −0.0219  (−52 % Betrag)
    //   maxH       0.6836 0.6206 0.5752 0.5639 0.5516 0.5383  (monoton)
    // Zum Vergleich derselbe Lauf mit dem alten Servo: relief 0.5335 → 0.4569 (30k)
    // → 0.5097 (100k), ridgeCurv ab 10k flach bei ≈ −0.030 — Plateau statt Alterung.
    // Multi-Seed (n=160, 100k, Seeds 1337/7/99/2024/555): maxH-Spitzenwert des
    // Laufs ist bei JEDEM Seed exakt der Startwert (keine Wachstumsphase), relief
    // fällt bei jedem. Die Gratkrümmung rundet bei 4 von 5 Seeds (z. B. −0.0306 →
    // −0.0169); Seed 7 startet als weiches Rollhügel-Terrain (curv0 −0.0173) und
    // wird erst einmal ZERSCHNITTEN (−0.0253) — die Kennzahl misst Rundung
    // relativ zum Startzustand, ein sehr junges glattes Terrain muss zuerst
    // Täler bekommen. Der Wächter `TerrainAging` misst deshalb auf Seed 1337.
    public var upliftDecayStartPer100y: Double = 0.0008   // U₀
    public var upliftDecayFloorPer100y: Double = 0.00008  // U_floor
    public var upliftDecayYears: Double = 40000           // τ

    // ---- Tektonik / Isostasie ----
    // KONSTANTE Alt-Hebung über das VOLLE Tektonik-Feld (inkl. negativer Täler).
    // Produktion 0 und bleibt 0 — die Tektonik läuft seit Issue #13 über die
    // abklingende Hebung oben (positiver Feldanteil, nur Land). Nur noch von
    // Testkonfigs gesetzt, die ihre alte Kalibrierung pinnen (`meanderCfg`).
    // Historische Begründung der 0:
    public var upliftPer100y: Double = 0.0 // KEINE Dauer-Tektonik → Berge wachsen NIRGENDS (auch keine lokalen Grate), sie erodieren nur — wie real ohne aktive Plattengrenze/Vulkanismus. Selbst 0.0015 schob mittlere Grate pro 10k-Klick noch sichtbar hoch (+0.03), obwohl der globale Gipfel erodierte. Hebung nur noch über Sculpting/Events. (War 0.009→0.0015→0.0.) (wie real ohne aktive Plattengrenze/Vulkanismus) statt bei jedem 10k-Schritt hochzuwachsen. 0.009 stockte die Landmasse in 100k um +73% auf (meanLand 0.39→0.68 → sichtbares „Wachsen"); 0.0015 hält die Masse ~flach (0.39→0.42), Relief erodiert sanft (0.76→0.65). Nur so viel Hebung, dass die Insel nicht wegerodiert.
    public var isoHighClamp: Double = 0.90 // Hebung → 0 gegen diese Höhe: deckelt das Relief-Runaway (Berge wuchsen sonst über 100k Jahre bis 1.25, Makro-Form lief weg). 0.90 pinnt Relief/maxH über 100k Jahre aufs junge Niveau (~0.75/0.90) — gratiges Gleichgewicht statt Alterung, ohne dass die Erosion die Berge abträgt (0.85 würde bereits erodieren)
    public var isoLowRange: Double = 0.35   // Senkung → 0 gegen den Boden

    // ---- Küste ----
    public var waveBand: Double = 0.06
    public var waveTalus: Double = 0.002
    // Stärke der Wellen-Relaxation JE 100-JAHR-TEILSCHRITT (0 = Küstenerosion
    // aus). Seit Issue #2 ist `wavePass` sub-getaktet wie die Hangdiffusion:
    // feste Teilschritt-Stärke, Anzahl ∝ dt (`Terrain.waveSchedule`). Vorher war
    // es eine Zählschleife `max(1, min(24, dt/100))` mit VOLLER Stärke je
    // Durchlauf — ein Zeitraffer-Schritt (dt ≈ 9…240 J.) bekam damit die volle
    // 100-Jahr-Relaxation, und ab dt > 2400 sättigte der Deckel. Gemessen
    // (n=192, 20k Jahre, Seed 1337, zeitgemittelt): Küstenzone 5529 Zellen bei
    // dt=10 gegen 4003 bei dt=240 und 4042 bei dt=2000 (Spanne 38 %) — nach dem
    // Fix 4118 / 4095 / 4137 (Spanne 1.0 %). Der Wert 0.5 ist unverändert und
    // bei dt = k·100 auch der Takt (k Teilschritte) — die Kalibrierung ist
    // gepinnt, nur die Schrittweiten-Abhängigkeit fällt weg.
    public var waveRelax: Double = 0.5

    // ---- Delta (Issue #174, Abnahmepunkt 26) ----
    // Fracht der Flüsse als Mündungsbarren vor der Mündung
    // (`Terrain.deltaDeposit`, Begründung und Ablauf dort). Vorher kam im
    // Meer vor den großen Mündungen fluvial praktisch nichts an (Seed 1337,
    // Jahr 20.000, größte Mündung: Einzugsgebiet −7,9 Zellen·Höhe je 1000 J.
    // über `outletIncision`, ins Meer davor fluvial −0,1…+0,1) — die Inzision ist
    // detachment-begrenzt, ihr Abtrag lag danach nirgends, und an keiner
    // Mündung der drei Matrix-Seeds stand eine Sandinsel. Messreihe und
    // Verworfenes: `docs/zielbild-measurements.md` § Delta.
    //
    // Gemessen wird Abnahmepunkt 26 mit `DeltaMetrics.shape`: Distributäre =
    // 1 + größte Zahl Inseln, die ein Bogen um die Mündung quert. Große
    // Mündungen (≥ 5000 Zellen) mit ≥ 3 Distributären und Sandinsel, Seeds
    // 1337 · 20 · 42, je Jahr 2000/20.000/100.000:
    //   aus (Integrationsstand 3bc20cc):          0/0/0 · 0/0/0 · 0/0/0
    //   Wahl (unten), Schrittweite 1000:           5/3/7 · 1/1/4 · 0/5/1
    //   Wahl (unten), Schrittweite 100:            4/1/6 · 3/3/4 · 2/3/2
    //   (auf 6a0dfde: 4/2/6 · 1/5/3 · 1/3/2 bzw. 5/4/3 · 4/4/4 · 0/2/2)
    // Erste Fassung (Kreisbarren rad 0,75, 2 Generationen, Fracht als D8-Summe
    // je Zelle, Mündungen ab 2000), Integrationsstand e2574d1:
    //   6/4/10 · 2/1/5 · 1/4/1 — Inseln 13–145 Zellen, alle Sand
    //   dto., Mündungen ab 320 Zellen:             5/3/3 · 3/4/3 · 1/4/3
    //   dto. plus Erosionsbasis sea − 0,002:       9/2/5 · 1/0/3 · 2/1/0
    // Auf dem älteren Stand 0fec08b (vor #187), Mündungen ab 320 Zellen:
    //   trap 0.5, dist 3, rad 1:                   1/0/4 · 0/0/2 · 0/0/1
    //   trap 0.5, dist 2, rad 0.75:                3/3/6 · 0/2/3 · 0/2/2
    //   trap 1.0, dist 2, rad 0.75:                5/5/7 · 3/5/2 · 3/2/1
    //
    // Anteil der Fracht einer Mündung (Einzugsgebiet × mittlerer Abtrag von
    // `outletIncision` + `channelCarve` je Landzelle in diesem Schritt), der
    // als Barre liegen bleibt; was die Barren nicht fassen (Baum voll), geht
    // als Schweb ins offene Meer. 1.0, weil mit 0.5 die Barren auf Seed 20
    // und 42 bis Jahr 2000 nicht auftauchten (Tabelle oben): der Schelf vor
    // den Mündungen fällt mit ~0,003 je Zelle ab, eine Barre zwei
    // Rinnenbreiten voraus steht in 0,03–0,04 Tiefe. Gürtel und Tropfen
    // liefern nichts zu (s. dort). 0 = Pass aus (bit-identisch zum Stand
    // davor).
    public var deltaTrapFraction: Double = 1.0
    // Kleinste Mündung (D8-Einzugsgebiet in Zellen), die ein Delta baut;
    // kleinere Läufe exportieren ihre Fracht wie bisher. Mit 320
    // (`channelFlowMinCells`) setzten auch Bäche Barren-Sprenkel vor die
    // Küste, und der Baum-Teil des Passes kostete mehr (0,2 statt 0,5–1,0 ms
    // je Schritt, `simperf`, erste Fassung). 2000 (Läufe mit Mäandergürtel,
    // `meanderBeltMinCells`) gab mit der Fracht nach Einzugsgebiet und den
    // größeren Barren noch Sprenkel vor mittleren Flüssen und kostete
    // `deltaDeposit` 0,60 statt 0,50 ms; 4000 liegt knapp unter der großen
    // Mündung der Kennzahl (5000).
    public var deltaMinCells: Double = 4000
    // Scheitel einer Mündungsbarre über dem Meer (Sim-Höhe, ≈ 3,6 m bei
    // `heightScale` 24): die Sandinsel. Unter `waveTalus` (0.002) gewählt: so
    // tief, dass die Wellen eine Rinne neben der Insel höchstens auf
    // sea − 0,0005 zuschütten — sie bleibt Wasser.
    public var deltaTopset: Double = 0.0015
    // Abstand der Mündungsbarre vor dem Strahlanfang, in Rinnenbreiten (die
    // Barre liegt einige Breiten vor der Mündung, Edmonds & Slingerland 2007).
    // 3 legte die Barren in tieferes Wasser und ließ sie seltener auftauchen
    // (Tabelle oben); auf dem Endstand bei Jahr 20.000 4/2/1 statt 4/1/4
    // Deltas.
    public var deltaBarDistanceWidths: Double = 2.0
    // Inselradius der Barre quer zum Strahl und stromauf, in Rinnenbreiten
    // (Fuß beim doppelten Radius). Mit 1 überlappten Fuß und Mündungsrinne,
    // die Barre brauchte mehr Fracht. 0,75 (erste Fassung) gab Inseln von
    // 13–145 Zellen, alle Sand; mit 0,9 und Streckung 2 (Jahr 20.000, Seeds
    // 1337/42/20) 3/4/3 Deltas, beste Inseln 95–162 Zellen mit Bewuchs, gegen
    // 4/3/2 mit 0,75 und Streckung 1,5 (`docs/zielbild-measurements.md`
    // § Delta, Verworfen).
    public var deltaBarRadiusWidths: Double = 0.9
    // Streckung der Barre stromab: Mündungsbarren sind Tropfen in
    // Fließrichtung, stromauf rund, stromab lang. Stromauf bleibt der Radius,
    // sonst reichte die Barre bei 2 bis in die Mündungsrinne zurück.
    public var deltaBarElongation: Double = 2.0
    // Winkel zwischen den beiden Töchtern einer Verzweigung (Bogenmaß,
    // ≈ 69°; Deltas verzweigen gemessen um ~70°, Coffey & Shaw 2017, GRL 44).
    public var deltaBifurcationAngle: Double = 1.2
    // Zahl der Verzweigungen hinter der ersten Barre. Mit
    // `deltaMinHalfWidth` endet ein Strahl vorher, wenn seine Töchter
    // schmaler würden.
    public var deltaGenerations = 3
    // Schmalste Rinne (Halbbreite in Zellen): darunter teilt sich ein Strahl
    // nicht mehr. Ohne Untergrenze gaben drei Generationen Enkel-Rinnen von
    // ~2 Zellen Breite, an der Auflösungsgrenze.
    public var deltaMinHalfWidth: Double = 1.2
    // Schwankung von Teilung, Winkel, Barrenabstand und -umriss (relativ, ±).
    // 0 gibt einen symmetrischen Baum.
    public var deltaJitter: Double = 0.3

    // ---- Höhenbänder (Issue #4): Perzentile statt absoluter Schwellen ----
    // Schnee-, Hochfels- und Vegetations-Höhengrenzen kommen aus Perzentilen der
    // AKTUELLEN Landhöhenverteilung (`HeightBands.fromLandHeights`, angewandt in
    // `Terrain.heightBands`). Begründung und Mechanik: HeightBands.swift.
    //
    // Kalibrier-Messung (n=832, Seed 1337, Produktions-Defaults; Rohdaten und
    // Verlauf: docs/height-band-measurements.md). Landhöhen-Quantile:
    //             p10    p50    p88    p91    p92    p95    p98.5  p99.5  p99.9  max
    //   Jahr 0  0.2346 0.3415 ~0.478 0.4986 0.5050 0.5279 0.5699 0.6018 0.6395 0.7457
    //   30k     0.2520 0.3552 ~0.481 0.4900 0.4962 0.5196 0.5596 0.5833 0.6026 0.6372
    // Die ALTEN absoluten Schwellen lagen damit bei:
    //   0.50 (veg voll)  = p91.2 → p92.6     0.58 (Graurampe) = p98.9 → p99.4
    //   0.68 (veg aus)   = p99.99 → p100     1.05 (Schnee)    = p100 (NIE erreicht)
    //   0.26/0.48 (Nadelbaum-Band) = p17.1/p87.8 → p11.4/p89.1
    // Die Perzentile unten sind genau darauf gesetzt: Vegetation und Nadelband
    // bleiben (Kalibrier-Kaskade! veg geht über `vegDamp` in die Erosion ein)
    // praktisch auf ihrer alten Höhe, während Fels und Schnee in den oberen
    // Bereich rücken, der vorher leer war.
    public var bandVegFullPercentile: Double = 0.91  // = die alte 0.50 (p91.2 bei der Generierung) — bewusst deckungsgleich gewählt, damit die Vegetations-Physik sich NICHT verschiebt.
    // Obere Vegetationsgrenze = vegFull + Faktor · (p95 − p50), also eine
    // ROBUSTE RELIEF-SPANNE breit (dasselbe Quantilpaar wie `landReliefRobust`).
    // Warum kein zweites Perzentil: die alte Obergrenze 0.68 lag bei p99.99 —
    // ein Perzentil dort hinge an den obersten paar Zellen (bei n=160 an 2), und
    // jedes robustere Perzentil (p99.9 = 0.6395) macht die Rampe SCHMALER als
    // bisher. Genau das ist keine Kosmetik: `veg` geht über `vegDamp` in die
    // Erosion ein. Gemessen (n=192, Seed 1337, 20k Jahre) kostete die schmalere
    // Rampe (p99.9) 2 % mittleres veg und 1.1 % Relief und kippte zwei
    // knapp gepinnte #12-Wächter (`testHardnessContrastHoldsSlopeBreak`,
    // `testEndorheicMechanicsSurviveLithology`) — auf `main` reicht dafür schon
    // eine Rampe von 0.18 auf 0.17 (Referenzarm-Signal 1.0517 → 1.0791 gegen die
    // 0.08-Schranke), die Kennzahl hängt also direkt an dieser Rampenbreite.
    // Faktor 1.0: die Rampe ist bei der Generierung 0.1864 breit (n=832, Seed
    // 1337) gegen die alten 0.18 — +3.6 %, und sie schrumpft mit der alternden
    // Landschaft mit (0.1644 nach 30k), statt als fixe Höhe stehen zu bleiben.
    public var bandVegRampSpanFactor: Double = 1.0
    public var bandRockPercentile: Double = 0.92     // Beginn der Hochlagen-Graurampe. War p98.9 (1.1 % des Landes, Kern der Issue-Beobachtung „99 % im schmalen Farbband"); p92 gibt den obersten 8 % einen sichtbaren Fels-Verlauf, ohne unter die Vegetationsgrenze (p91) zu rutschen.
    public var bandRockFullPercentile: Double = 0.995 // voll ausgegraut. Alt: 0.98 absolut = jenseits von maxH, die Rampe kam real nie über 41 %.
    // SEIT ISSUE #33 NUR NOCH RÜCKFALL: die Schneegrenze kommt aus dem Schneefeld
    // (Massenbilanz, s. Abschnitt „Klima-Vertikale" unten). Diese beiden
    // Perzentile greifen nur, wenn `climateEnabled = false` ist — dann rechnet
    // alles bit-identisch wie vor #33. Die Herleitung darunter beschreibt also
    // den Stand von #4.
    public var bandSnowPercentile: Double = 0.985    // Beginn Schnee: oberste 1.5 % des Landes (n=832: ~7200 Zellen in der Rampe). Alt 1.05 absolut = 0 Zellen. Der Wert ist gesetzt, nicht gemessen: die Perzentil-Konstruktion legt den Flächenanteil fest, gemessen ist nur, DASS er über den Lauf steht (1.51 % → 1.49 %, s. docs). Enger (p99.5 = 0.5 %) wäre Streusel, weiter (p95 = 5 %) würde ganze Kammlinien weißen.
    public var bandSnowFullPercentile: Double = 0.9985 // voll weiß: oberste 0.15 % (~720 Zellen bei n=832) — die eigentlichen Gipfel.
    public var bandConiferLowPercentile: Double = 0.15 // Baum-Variante Laub→Nadel: entspricht der alten 0.26 (p17.1 bei der Generierung, p11.4 nach 30k).
    public var bandConiferHighPercentile: Double = 0.88 // entspricht der alten 0.48 (p87.8 → p89.1).
    // Mindestbreite jeder Rampe: eine (fast) ebene Insel hat identische Quantile —
    // ohne Untergrenze würde aus dem Verlauf eine harte Kante.
    public var bandMinRampWidth: Double = 0.004
    /// FESTE Bänder statt der Ableitung aus der Verteilung. In der Produktion
    /// `nil` — gedacht für Wächter, die an EINEM konkreten Becken/Lauf hängen und
    /// deshalb ihre alte Kalibrierung pinnen (dieselbe Doktrin wie `meanderCfg()`
    /// in SimCoreTests und wie `lithologyEnabled = false` in den #11-Wächtern).
    /// Mit `HeightBands.legacyAbsolute` läuft die Vegetation exakt wie vor
    /// Issue #4.
    public var heightBandsOverride: HeightBands? = nil

    // ---- Klima-Vertikale: Temperaturfeld und Schneedecke (Issue #33) ----
    //
    // Bis #33 war Schnee reine FARBE: `bandSnowPercentile` malte die obersten
    // 1,5 % des Landes weiß, kein Feld und kein Pass las das. Jetzt gibt es zwei
    // Felder (`Terrain.temperature`, `Terrain.snow`) und eine Massenbilanz:
    //
    //     T(k)   = climateSeaLevelTemp − climateLapseRate · max(0, h[k] − sea)
    //     a(k)   = snowAccumPerYear · rain[k] · f_schnee(T)          Akkumulation
    //     μ(k)   = 1/snowTurnoverYears + snowMeltPerKYear · max(0, T) Ablationsrate
    //     dS/dt  = a − μ·S      ⇒  S ← S* + (S − S*)·e^(−μ·dt),  S* = a/μ
    //
    // Herleitung, Primärquellen und die verworfenen Modellvarianten:
    // `docs/research-climate-cryosphere.md`. Messreihen: `docs/climate-snow-measurements.md`.
    //
    // AUS (`climateEnabled = false`): alle drei Kryo-Felder bleiben LEER, die
    // Schneegrenze fällt auf die Perzentile oben zurück und die Färbung rechnet
    // exakt wie vor #33 (Muster wie Lithologie/Regen-Gewichtung; Wächter
    // `ClimateSnow.testDisabledClimateIsBitIdenticalPhysics` und
    // `testDisabledClimateFallsBackToThePercentileBands`).
    //
    // WAS DAS KLIMA (NOCH) NICHT TUT: es koppelt in KEINEN Erosionspass und nicht
    // in die Vegetation. Bewusste Scope-Grenze — jede solche Kopplung liefe über
    // `vegDamp` bzw. direkt in die Raten und würde die gesamte Kalibrier-Kaskade
    // (Braiding-Gates, Relief-Wächter, Becken-Rollen) aufmachen. Die Kopplung an
    // die Physik kommt mit dem EIS (#35), das dafür sein eigenes Erosionsgesetz
    // mitbringt. Heute sind Temperatur und Schnee: persistenter Zustand,
    // Schnee-Färbung und Waldgrenze.
    public var climateEnabled = true
    /// Temperatur auf Meereshöhe (°C) — der zweite Freiheitsgrad der
    /// Höhen-Temperatur-Kopplung neben `climateLapseRate`.
    ///
    /// GEWÄHLT 11 °C aus der Anschluss-Bedingung an den bisherigen Look: die
    /// 0-°C-Isotherme soll bei der Generierung dort liegen, wo der Perzentil-Schnee
    /// begann. `h(T=0) = sea + T₀/Γ = 0.15 + 11/26 = 0.573` gegen den gemessenen
    /// p98.5 = 0.5699 (n=832, Seed 1337, `docs/height-band-measurements.md`).
    /// Das ist der EINZIGE Punkt, an dem die alte Perzentil-Kalibrierung noch
    /// durchschlägt, und bewusst nur als Startwert: ab da bewegt das Klima die
    /// Grenze, nicht mehr ein fixer Flächenanteil.
    ///
    /// 11 °C Jahresmittel auf Meereshöhe ist auch für sich plausibel (grob
    /// Südnorwegen/Nordschottland) und passt zu der kühl-maritimen Insel, die
    /// schon die Verdunstungs-Kalibrierung annimmt (κ = 1.25 ≙ E ≈ 1.08·P,
    /// s. `endorheicEvapRatio`).
    public var climateSeaLevelTemp: Double = 11.0
    /// Temperaturgradient in **K je Höheneinheit** — die Kalibrier-Entscheidung
    /// dieses Tickets, weil es KEINEN vertikalen Meter-Maßstab gibt (`h` ist
    /// normiert, `world`/`cellSize` koppeln nur horizontal).
    ///
    ///     Γ = 6,5 K/km (ICAO-Standardatmosphäre bis 11 km) × H_ref
    ///     H_ref = 4000 m je Höheneinheit  ⇒  Γ = 26 K/Einheit
    ///
    /// H_ref = 4000 m macht den höchsten Punkt der frischen Insel zu
    /// `(0.7457 − 0.15)·4000 ≈ 2380 m` — ein alpines Mittelgebirge mit echter
    /// Höhenstufung. VERWORFEN:
    /// * H_ref = 2000 m (Γ = 13): Gipfel 1190 m. Bei jedem T₀, das die Küste
    ///   eisfrei hält (> 5 °C), läge die 0-°C-Grenze ÜBER dem Gipfel — es gäbe nie
    ///   Schnee, das Feature wäre stumm.
    /// * H_ref = 8000 m (Γ = 52): Gipfel 4766 m. Das obere Drittel stünde
    ///   dauerhaft unter Frost, und die alternde Insel (maxH 0.7457 → 0.6372 nach
    ///   30k J.) würde die Schneezone kaum noch bewegen — genau die Trägheit, die
    ///   das Ticket abschaffen will.
    /// Der ISA-Wert (statt trocken- 9,8 oder feuchtadiabatisch 3,6–9,2 K/km) ist
    /// der richtige Kompromiss für eine feuchte maritime Insel.
    public var climateLapseRate: Double = 26.0
    /// Niederschlagsphase, untere Schwelle (°C): darunter fällt ALLES als Schnee.
    /// Zusammen mit `snowRainTemp` die Doppelschwellen-Rampe (Kienzle 2008,
    /// USACE) statt einer harten Kante — eine harte Schwelle schnitte eine
    /// Sprungkante ins Feld.
    /// −1 / +3 legt den 50-%-Punkt auf +1 °C: exakt das Nordhemisphären-Mittel aus
    /// Jennings et al. 2018 (17,8 Mio. Beobachtungen; 95 % der Stationen zwischen
    /// −0,4 und +2,4 °C).
    public var snowFreezeTemp: Double = -1.0
    /// Niederschlagsphase, obere Schwelle (°C): darüber fällt alles als Regen.
    public var snowRainTemp: Double = 3.0
    /// Akkumulation je Jahr bei Regenrate 1 und reinem Schneefall
    /// (SWE-Einheiten/Jahr). Legt zusammen mit `snowTurnoverYears` die EINHEIT des
    /// Schneefelds fest: bei Dauerfrost (T ≤ `snowFreezeTemp`, also reiner
    /// Schneefall UND keine Schmelze) ist μ = 1/τ₀ und damit
    /// `S* = snowAccumPerYear · snowTurnoverYears · rain = 1.0 · rain` — SWE 1.0
    /// heißt „voll ausgebildete Dauerschneedecke am feuchtesten Standort".
    /// Eine absolute Kalibrierung in mm w.e. gibt es bewusst nicht: auch `rain`
    /// ist eine abstrakte Feuchte (0,18 … 1,0), keine Niederschlagshöhe.
    public var snowAccumPerYear: Double = 0.002
    /// GRUNDUMSATZ der Schneedecke (Jahre): der additive Sockel `1/τ₀` in der
    /// Ablationsrate μ. Drei Aufgaben, alle drei nötig:
    /// 1. Er hält `S* = a/μ` BESCHRÄNKT. Ohne ihn ginge S* an der Frostgrenze
    ///    (μ → 0) gegen unendlich, und eine 200k-Jahre-Welt bekäme numerisch
    ///    entgleiste Schneetürme auf den Gipfeln.
    /// 2. Er ist physikalisch besetzt: Sublimation und Windverfrachtung tragen
    ///    auch bei Dauerfrost ab (auf antarktischen Blaueisfeldern ist Sublimation
    ///    der einzige Ablationsterm).
    /// 3. Er ist der Anschlusspunkt für das Eis (#35): was oberhalb der
    ///    Gleichgewichtslinie aus dem Schneevorrat abfließt, ist real die
    ///    Firn→Eis-Umwandlung; dort wird genau dieser Term in `Terrain.ice`
    ///    gebucht statt verworfen.
    /// 500 Jahre = die Antwortzeit eines Dauerschneefelds auf Klima-/Terrain-
    /// änderung. Dieselbe Größenordnung wie die übrigen trägen Relaxationen des
    /// Repos (`endorheicResponseYears` 500, `lakeLevelResponseYears` 250).
    public var snowTurnoverYears: Double = 500
    /// Zusätzliche Ablations-RATENKONSTANTE je K Jahresmittel über 0 °C
    /// (1/(Jahr·K)) — das degree-day-Modell (Hock 2003) in Relaxationsform.
    ///
    /// WARUM RATENKONSTANTE statt fester Schmelzmenge: die klassische Form
    /// `S ← max(0, S + (a − m)·dt)` ist NICHT dt-invariant — sie bricht genau am
    /// Ausapern, weil das `max` in einem großen Schritt Schmelzguthaben verwirft,
    /// das dieselbe Zeit in kleinen Schritten noch gegen frischen Schneefall
    /// verrechnet hätte (dieselbe Fehlerklasse wie `max(1, …)` bei der
    /// Tropfenzahl, AGENTS.md). `dS/dt = a − μ·S` hat dagegen die geschlossene
    /// Lösung `S* + (S−S*)·e^(−μdt)`, teleskopiert exakt über beliebig viele
    /// Teilschritte und braucht kein Clamping (aus S ≥ 0, a ≥ 0 folgt S ≥ 0).
    /// Physikalische Lesart: anteilige Ablation — eine tiefe Decke apert später
    /// aus als eine dünne. Für ein Modell OHNE Jahresgang ist das die richtige
    /// Glättung; real verteilt die Schmelzsaison das Ausapern ebenso.
    ///
    /// Der Wert steuert die BREITE des Übergangs. Über der Frostgrenze gilt
    /// `S*/S*(ΔT=0) = 1/(1 + c·τ₀·ΔT)`; der Vorrat fällt also auf 1/x bei
    /// `ΔT = (x−1)/(c·τ₀)`. Für den SICHTBAREN SAUM (Deckung 0.5 → 0.05, also
    /// Faktor 19 im Vorrat) sind das `18/(c·τ₀·Γ)` Höheneinheiten.
    ///
    /// Sweep (n=192, Seed 1337, Produktionspfad; Saumbreite / Landanteil bei
    /// Jahr 0: sichtbar (Deckung > 0.05) / Rampe (> `snowBandCoverStart`) / voll
    /// (≥ `snowBandCoverFull`); Rohdaten `docs/climate-snow-measurements.md` §2,
    /// Wächter `ClimateSnow.testMeltRateSweepDiagnostic`):
    ///   c = 0.02 → 0.0692 Einheiten · 9.08 % / 1.65 % / 0.74 %
    ///   c = 0.06 → 0.0231 Einheiten · 4.98 % / 1.38 % / 0.73 %   ← gewählt
    ///   c = 0.20 → 0.0069 Einheiten · 2.35 % / 1.30 % / 0.73 %
    /// GEWÄHLT 0.06. Die substanzielle Schneefläche (1.38 %) trifft die alte
    /// Perzentil-Kalibrierung (1.5 %, `bandSnowPercentile`) fast auf den Punkt —
    /// der Look bleibt beim Umstieg erhalten. 0.02 verwäscht den Saum über 9 %
    /// des Landes (Schleier statt Gipfelschnee); 0.20 drückt ihn auf 0.007
    /// Höheneinheiten, also unter die Höhendifferenz einer einzelnen Zelle an
    /// mittleren Hängen — eine harte, aliasende Kante.
    public var snowMeltPerKYear: Double = 0.06
    /// Sättigungs-Referenz der DECKUNG: `Deckung = S / (S + snowCoverRef)`.
    /// Dieselbe Bauform wie die Stream-Map (`streamRefRate`): eine harte
    /// SWE-Schwelle wäre eine Kante, eine lineare Rampe bräuchte ein zweites
    /// Maximum. Bei S = snowCoverRef ist die Zelle halb bedeckt.
    /// 0.10 gegen ein Maximum von S* ≈ rain ≤ 1.0: die Gipfel kommen auf Deckung
    /// ~0.9 (nicht 1.0 — die Sättigung ist asymptotisch, das ist gewollt: „fast
    /// ganz weiß" statt einer Volltonfläche), der Fuß der Zone fällt schnell ab.
    public var snowCoverRef: Double = 0.10
    /// Ab dieser DECKUNG zählt eine Zelle für das Höhenband als beschneit
    /// (`HeightBands.snowStart`) — und damit für die WALDGRENZE.
    /// Die Färbung liest das Feld je Zelle; die Waldgrenze bleibt eine HÖHE
    /// (`HeightBands`-Vertrag, reist im Spielstand mit und geht an den Shader),
    /// wird aber aus dem Feld zurückgerechnet: gemessener Landanteil mit Deckung
    /// über dieser Schwelle → Höhenquantil, das genau diesen Anteil abschneidet.
    /// „Schneezone = Flächenanteil X" gilt also weiter, aber X ist GEMESSEN statt
    /// konfiguriert und folgt dem Klima.
    /// 0.5 = halb bedeckt, also `S ≥ snowCoverRef`.
    public var snowBandCoverStart: Double = 0.5
    /// Ab dieser Deckung gilt eine Zelle als voll beschneit (`snowFull`).
    /// Reiner BAND-Parameter: die Färbung liest seit #33 das Feld je Zelle, die
    /// obere Bandgrenze hält nur noch `HeightBands` wohlgeformt und geht als
    /// Zahl an Shader/Diagnose.
    /// 0.8 ⇒ `S ≥ 4·snowCoverRef = 0.4`, knapp unter der asymptotischen
    /// Obergrenze der Deckung (gemessen n=832, Seed 1337: Smax 0.660 bei der
    /// Generierung → Deckung 0.87). VERWORFEN 0.85: das Voll-Band war schon bei
    /// der Generierung praktisch leer (< 0.005 % des Landes) und `snowFull`
    /// rutschte nach 30k Jahren ÜBER den Gipfel (0.6361 gegen maxH 0.6359) — das
    /// Band existierte dann nicht mehr. Mit 0.8 bleibt es über den ganzen Lauf
    /// unter dem Gipfel (0.6683 / 0.6424 / 0.6161 bei J0 / 10k / 30k).
    /// Dass der Voll-Anteil mit der alternden Insel trotzdem winzig bleibt
    /// (0.02 %, Smax 0.660 → 0.438), ist gewollt: die Insel wächst nicht mehr in
    /// die Höhe, in der das Klima Dauerschnee trägt.
    public var snowBandCoverFull: Double = 0.8

    // ---- Schmelzwasser speist den Abfluss (Issue #36) ----
    //
    // Bis #36 war die Schneedecke hydrologisch stumm: sie färbte und verschob die
    // Waldgrenze, aber der Abfluss kannte nur den REGEN. Jetzt speist die
    // Ablation die Abfluss-Akkumulation — und zwar über den EINEN Trichter
    // `Terrain.seedFlowAccumulator`/`Terrain.flowWeight`, damit alle drei
    // Konsumenten (D8-`area` → Erosion, MFD-`areaMFD` → Render/Braiding und die
    // Tropfen-Startpunkte) derselben Gewichtungsregel folgen.
    //
    //     Schmelzfluss  m(k) = snowMeltPerKYear · max(0, T) · S      [SWE/Jahr]
    //     Regen-Einheiten      m(k) / snowAccumPerYear
    //     roh           w(k) = rain[k] + m(k)/snowAccumPerYear
    //
    // Die Umrechnung über `snowAccumPerYear` ist keine freie Konstante, sondern
    // die Umkehrung der Akkumulation (`a = snowAccumPerYear · rain · f_schnee`):
    // eine Zelle, die ihren gesamten Festniederschlag wieder abschmilzt, bekommt
    // damit genau `rain · f_schnee` als Schmelzbeitrag zurück. Daraus folgt die
    // OBERGRENZE des Beitrags im eingeschwungenen Zustand:
    // `m/snowAccumPerYear = rain · f_schnee · (c·T)/(1/τ₀ + c·T) ≤ rain`.
    // Das Gewicht kann sich also höchstens VERDOPPELN — wichtig für die
    // Ablehnungs-Stichprobe der Tropfen-Starts, die mit dem Feld-Maximum
    // normiert (ein Ausreißer-Maximum würde dort die Annahmequote erdrücken).
    //
    // NICHT dabei: der Grundumsatz-Sockel `1/snowTurnoverYears` der Ablation.
    // Der ist bei `snowTurnoverYears` als Sublimation/Windverfrachtung und als
    // Anschlusspunkt für die Firn→Eis-Umwandlung (#35) besetzt — beides fließt
    // nicht ab. Konsequenz: oberhalb der 0-°C-Isotherme (T ≤ 0, kein
    // Schmelzterm) liefert eine Zelle keinen Schmelzbeitrag, der Beitrag sitzt im
    // ABLATIONSSAUM darunter. Genau dort will das Ticket das Wasser haben.
    //
    // DIE DESIGNENTSCHEIDUNG (gemessen, `docs/melt-runoff-measurements.md`):
    // Renormierung (`meltRunoffNormalized = true`, gewählt) gegen Zusatzwasser.
    // Renormiert wird das Landmittel des ROHEN Gewichts wieder auf 1 gezogen —
    // Σ Gewicht über Land = Zahl der Landzellen bleibt exakt erhalten (dieselbe
    // Invariante wie bei #10), der Schmelzbeitrag wirkt als UMVERTEILUNG in die
    // schneegespeisten Einzugsgebiete. Kein in Zellen kalibriertes Gate
    // (Braid-, Render-, Mäander-Schwellen, `minAreaCells` des Breach) musste
    // angefasst werden, und `totalOutletArea()` bleibt auf die Zellzahl gepinnt.
    // Physikalische Lesart der Renormierung: nicht der Niederschlag ist neu
    // verteilt, sondern der ABFLUSSKOEFFIZIENT — schneegespeiste Einzugsgebiete
    // führen je Einheit Niederschlag mehr Wasser (kaum Verdunstung, keine
    // Vegetation, Schmelzspitzen) als warmes, bewachsenes Tiefland. Das ist der
    // Effekt, den das Ticket beschreibt; die Gesamtwassermenge der Insel ist
    // dagegen eine KALIBRIERTE Größe und kein Messergebnis dieses Tickets.
    public var meltRunoffEnabled = true
    /// Normierungs-Arm der Schmelz-Gewichtung. `true` (Default) = Renormierung:
    /// das Landmittel des rohen Gewichts wird auf 1 gezogen, Σ über Land bleibt
    /// exakt die Zahl der Landzellen.
    ///
    /// `false` = ZUSATZWASSER (verworfener Arm, bleibt als Referenz messbar): das
    /// Gewicht wird mit demselben Divisor wie `rainWeight` normiert (Landmittel
    /// des Regens), die Schmelze kommt also OBEN DRAUF und die Summe steigt.
    /// Gemessen (n = 192, 20.000 Jahre, Produktionspfad, alpine Seeds
    /// 1337/2/6/20/33): `totalOutletArea/Zellzahl` = 1.0000 renormiert gegen
    /// 1.0078 … 1.0175 als Zusatzwasser — die 0.8 … 1.8 %, die die Ablationszone
    /// dieser Inseln ausmacht. Der Preis wäre die volle Kalibrier-Kaskade (jedes
    /// in Zellen kalibrierte Gate neu vermessen, Erosionsraten nachziehen), und
    /// der Faktor hängt an Seed und Auflösung — genau der Fehler, den #10 mit der
    /// Normierung abgestellt hat (dort: Landmittel des Regens 0.36 … 0.56 je
    /// Seed/Auflösung). Der GEWINN wäre dabei null: die Richtung des Effekts ist
    /// in beiden Armen dieselbe und praktisch gleich groß (gepoolter Abfluss
    /// schneegespeist/schneefrei 0.959 renormiert gegen 0.965 als Zusatzwasser,
    /// Aus-Arm 0.838), s. `docs/melt-runoff-measurements.md` §D.
    public var meltRunoffNormalized = true
    /// Anteil des FESTNIEDERSCHLAGS, der aus dem sofortigen Abfluss
    /// herausgenommen und der Schneedecke zugeschlagen wird
    /// (`rain · f_schnee · meltRunoffWithholdSolid`). 0 = aus (Default).
    ///
    /// VERWORFENER, weil ohne Eis (#35) falsch wirkender Arm — mit Messwerten
    /// (`docs/melt-runoff-measurements.md` §E): 1.0 wäre die massenkonsistente
    /// Buchung (was als Schnee fällt, fließt erst beim Schmelzen ab, kein
    /// Wasser wird doppelt gezählt). Ohne EIStransport schmilzt der Schnee aber
    /// genau dort, wo er fällt, und oberhalb der 0-°C-Isotherme schmilzt er nie:
    /// die Dauerfrostzone verliert ihren gesamten Abflussbeitrag an einen Speicher,
    /// der nie wieder ausschüttet (nur der Sublimations-Sockel zieht ab). Gemessen
    /// wird damit genau das GEGENTEIL des Ticket-Ziels — der Abfluss unter den
    /// schneereichsten Einzugsgebieten SINKT (Verhältnis schneegespeist/schneefrei
    /// gepoolt über 5 alpine Seeds: 0.765 gegen 0.838 im Aus-Arm und 0.959
    /// renormiert), und die Kammlinien-Quellflüsse trocknen aus. Der Arm bleibt als
    /// Stellschraube erhalten: mit #35 wandert das eingelagerte Wasser als Eis
    /// talwärts und schmilzt am Gletschertor — dann ist er die richtige Buchung.
    public var meltRunoffWithholdSolid: Double = 0
    /// Deckel des Schmelzbeitrags als VIELFACHES des lokalen Niederschlags: das
    /// Gewicht einer Zelle kann damit höchstens `(1 + Deckel)·rainWeight` werden.
    /// Er greift deshalb am NORMIERTEN Gewicht (und zusätzlich schon am Rohwert,
    /// damit der Normierungs-Divisor selbst ausreißerfrei bleibt): bei
    /// `meltRunoffWithholdSolid > 0` liegt das Landmittel des rohen Gewichts unter
    /// dem Regenmittel, die Renormierung hebt also alle Zellen an und ein nur roh
    /// gedeckelter Ausreißer läge danach über der Zusage — gemessen 2.0123 statt
    /// ≤ 2.0 im Sculpt-Fall (`docs/melt-runoff-measurements.md` §H).
    ///
    /// 1.0 ist keine gewählte Zahl, sondern die eingeschwungene OBERGRENZE selbst
    /// (`m/snowAccumPerYear = rain · f_schnee · (c·T)/(1/τ₀ + c·T) ≤ rain`, s.
    /// oben) — im normalen Lauf bindet der Deckel deshalb nie. Er bindet in genau
    /// einem Fall, und dafür ist er da: der SPIELER trägt eine beschneite Kuppe ab
    /// (`sculpt`/`flatten` → `SimNode.recomputeFlow`). Dann steht die Temperatur
    /// sofort auf Tieflandwert, die Schneebilanz aber noch auf dem alten Vorrat
    /// (`updateClimate(dt: 0)` zieht bewusst nur die Temperatur nach) — der rohe
    /// Schmelzterm wäre für einen Schritt `30·T·S`, bei T = 11 °C und S = 1.0 also
    /// das 330-fache des Regens. Das wäre eine Punkt-Quelle im Abflussfeld und
    /// würde zusätzlich die Ablehnungs-Stichprobe der Tropfen-Starts erdrücken
    /// (sie normiert auf das FELD-Maximum, ein Ausreißer drückt die Annahmequote
    /// aller anderen Zellen auf ~0). Mit dem Deckel bleibt der Eingriff eine
    /// erhöhte Schmelze statt eines Ausreißers, und die Bilanz apert im nächsten
    /// echten Schritt regulär aus.
    /// Wächter: `MeltRunoff.testMeltContributionIsCappedAtTheLocalRain` und
    /// `MeltRunoff.testMeltContributionStaysCappedWithSolidWithholding`
    /// (derselbe Fall mit `meltRunoffWithholdSolid = 1`).
    public var meltRunoffCapPerRain: Double = 1.0

    // ---- Gletscher: Eisfluss und glaziale Erosion (Issue #35) ----
    //
    // #33 hat das Feld `Terrain.ice` angelegt und konstant 0 gelassen; hier wird
    // es beschrieben. Der Pass (`Terrain.updateIce`) hat drei Teile, alle in EINEM
    // sub-getakteten Takt (Vorbild `hillslopeDiffusion`):
    //
    //     1. TRANSPORT   Eis fließt auf der EIS-OBERFLÄCHE s = h + ice bergab.
    //                    Zwei-Phasen-Scratch, Fluss je Kante ∝ Dicke × Gefälle,
    //                    Ausstrom je Zelle gedeckelt (`iceFlowMoveFraction`).
    //     2. EROSION     E = iceErodeK · q^m · S      (Flux-Modell, m = iceErodeFluxExp,
    //                    q = Dicke × Oberflächen-Gefälle, S = Gefälle; n = 1 fix).
    //     3. BILANZ      dI/dt = a − μ·I  in Relaxationsform (exakt, wie beim Schnee):
    //                    a = iceFirnPerSnowYear · snow · f_kalt(T)   Firn→Eis
    //                    μ = 1/iceTurnoverYears + iceMeltPerKYear · max(0, T)
    //                    Was über den SCHMELZ-Anteil von μ verschwindet, legt seine
    //                    Schuttfracht als MORÄNE ab (`iceMoraineK`).
    //
    // MODELLWAHL: `docs/research-climate-cryosphere.md` §4.3 entscheidet für das
    // FLUX-Modell (Hergarten 2021 / Liebl et al. 2023) und GEGEN die nichtlineare
    // SIA-Diffusion — deren Zeitschritt-Deckel hängt an `H^{n+2}` und ist mit dem
    // `+10.000 Jahre`-Sprung dieses Projekts nicht budgetierbar. Das
    // Erosionsgesetz oben IST das Flux-Modell (§5, m = 0.5, n = 1). Der TRANSPORT
    // ist dagegen ein linearer, sub-getakteter Diffusions-Pass: er hat ein
    // KONSTANTES kappa und damit denselben, budgetierbaren Deckel wie die
    // Hangdiffusion — nicht den `H^5`-Deckel der SIA. Warum überhaupt Transport,
    // statt den Eisfluss wie Liebl et al. je Schritt auf dem D8-Baum zu
    // akkumulieren: eine Gletscher-ZUNGE ist genau die Stelle, an der das Eis
    // WEITER reicht als seine Massenbilanz — sie entsteht nur, wenn Eis als
    // Vorrat talwärts wandert. Eine Akkumulation je Schritt hätte Eis exakt dort,
    // wo es auch akkumuliert (Kare, keine Zungen).
    //
    // AUS (`iceEnabled = false`): der Pass läuft nicht, `ice` bleibt auf dem Wert
    // aus `updateClimate` (konstant 0), die Maske `Terrain.underIce` bleibt leer
    // und beide Gates fallen weg → bit-identisch zu #33/#36. Dasselbe gilt
    // solange KEINE Zelle Eis trägt (Wächter `Glacier.testDisabledIceIsBitIdentical`,
    // `testIcelessWorldIsBitIdentical`). Auch die GENERIERUNG bleibt eisfrei:
    // `generate` schwingt nur das Klima ein (`updateClimate(dt: 10000)`), das Eis
    // wächst ab Jahr 0 — dieselbe Begründung wie beim Schmelzwasser (#36), die
    // kalibrierte Welt-Erzeugung darf sich nicht verschieben.
    //
    // DT-INVARIANZ (Nachtrag Issue #174, `docs/glacier-measurements.md` §L): in
    // der Produktion hing die Eismasse an der Schrittweite — Jahr 20.000, dt 100
    // gegen 1000: 49 / 122 (Seed 1337), 65 / 31 (42), 159 / 53 (20); der
    // Zeitraffer-Takt dt 15 lag bei dt 100. Drei Ursachen, alle Kopplungen
    // eines großen Schritts an Größen vom Schrittanfang, keine davon in der
    // Bilanz selbst:
    //   1. Die Sub-Taktung deckelte nur den Ausstrom-Anteil `kappa·ΣΔs⁺`, nicht
    //      die Diffusionszahl `kappa·I` der Eis-Oberfläche → dickes Eis auf
    //      flachem Bett lief bei großen Schritten instabil (s. `iceFlowSubCap`).
    //   2. `fillShallowPonds` liest `hf` vom Schrittanfang und hielt alles, was
    //      der Gletscher im selben Schritt tiefer als 0,001 schliff, für eine
    //      Pfütze → füllte es zum Teil wieder auf, nur in großen Schritten.
    //      Unter dem Eis verlandet seitdem nichts mehr (`underIce`).
    //   3. Die Temperatur kam aus dem Feld vom Schrittanfang; der Schliff senkt
    //      das Bett aber über den Schritt → der Teilschritt rechnet sie jetzt
    //      aus dem Bett, das er vor sich hat (reine Funktion von `h`).
    // Jede Ursache allein zu beheben reichte nicht (gemessen, §L). Danach
    // liegen dt 15 / 100 / 1000 auf allen drei Seeds beieinander (Tabelle §L);
    // Wächter `Glacier.testIceIsFramerateIndependent` (Schrittpaare aus
    // demselben Zustand, volle Physik) und
    // `Glacier.testThickIceTransportIsStableForLargeSteps`.
    //
    // Messreihen: `docs/glacier-measurements.md`.
    public var iceEnabled = true
    /// Umrechnung Schneevorrat → EISZUFUHR: Höheneinheiten Eis je Jahr und
    /// SWE-Einheit Schnee (`a = iceFirnPerSnowYear · snow · f_kalt`).
    ///
    /// Das ist die zweite freie Maßstabs-Entscheidung der Kryosphäre — genau wie
    /// H_ref bei `climateLapseRate`: `snow` ist ein abstraktes SWE, `ice` eine
    /// Höhe, und es gibt keine physikalische Brücke zwischen beiden Einheiten.
    /// Angesetzt ist der Firn→Eis-Umsatz aus `docs/research-climate-cryosphere.md`
    /// §3 (der `1/snowTurnoverYears`-Sockel der Schneebilanz), also
    /// `snow/snowTurnoverYears = snow · 0.002` je Jahr, mal dem Anteil, der
    /// wirklich zu Gletschereis wird statt zu sublimieren.
    ///
    /// Die Dicke, die daraus wird, setzt NICHT `iceTurnoverYears`, sondern die
    /// KONTINUITÄT: Eis stapelt sich, bis seine Oberfläche steil genug steht, um
    /// die Zufuhr abzuführen (`kappa·I·ΣΔs⁺ = a`) — genauso wie eine echte
    /// Eiskappe. Der Grundumsatz ist nur die Obergrenze für den Fall, dass gar
    /// kein Gefälle mehr da ist (s. `iceTurnoverYears`).
    ///
    /// GEMESSEN statt hergeleitet (n = 384, Seed 1337, 50k Jahre, Zieldicke
    /// 100–400 m ≙ 0.025 … 0.1 Höheneinheiten bei H_ref = 4000 m;
    /// `docs/glacier-measurements.md` §B):
    ///   2e-5 → max 0.038, Reichweite 0.003 — die Zunge kommt nicht aus dem Kar
    ///   1e-4 → max 0.097, Reichweite 0.098
    ///   1e-3 → max 0.106 … 0.215, Reichweite 0.042 … 0.105   ← gewählt
    /// GEWÄHLT 1e-3: erst bei dieser Zufuhr FÜLLT das Eis die Täler (statt den
    /// Fels nur zu drapieren), und nur gefülltes Eis hat eine glatte Oberfläche,
    /// über die es quer zum Tal schleift — die V→U-Kennzahl trennt sich erst hier
    /// sauber vom eisfreien Referenzarm (§D). Der Faktor gegen den vollen
    /// Firn-Umsatz (`snow/snowTurnoverYears = snow·0.002`) ist damit 0.5: die
    /// Hälfte des Schnee-Grundumsatzes wird Gletschereis, die andere bleibt
    /// Sublimation/Windverfrachtung (die anderen zwei Aufgaben von
    /// `snowTurnoverYears`).
    public var iceFirnPerSnowYear: Double = 1e-3
    /// Temperaturspanne (K) unter der Gleichgewichtslinien-Temperatur
    /// `iceFirnTemp`, über die die Firn→Eis-Umwandlung hochrampt:
    /// `f_kalt = clamp((iceFirnTemp − T) / iceFirnColdSpan, 0, 1)`.
    ///
    /// Warum eine eigene, KÄLTERE Schwelle als die Niederschlagsphase
    /// (`snowFreezeTemp`/`snowRainTemp`, 50 % bei +1 °C): dass Schnee FÄLLT, heißt
    /// nicht, dass er den Sommer überdauert. Gletschereis entsteht nur oberhalb
    /// der Gleichgewichtslinie, und die liegt im Jahresmittel unter 0 °C.
    /// 2 K Rampe statt harter Kante aus demselben Grund wie bei der
    /// Niederschlagsphase — eine Kante im Feld aliast über die Höhenlinie.
    /// Bei Produktionswerten (Γ = 26, T₀ = 11) und `iceFirnTemp = 0` wären das die
    /// Höhen ab `h = 0.573` (Beginn) bzw. `h = 0.65` (volle Umwandlung); die
    /// Produktion liegt seit #174 um `iceFirnTemp` höher (s. dort).
    public var iceFirnColdSpan: Double = 2.0
    /// **Gleichgewichtslinien-Temperatur des Eises** (°C): unterhalb davon
    /// beginnt die Firn→Eis-Umwandlung (`iceFirnColdSpan` rampt darunter hoch).
    /// Entkoppelt die Firn-Grenze des EISES von der 0-°C-Isotherme, an der der
    /// Dauerschnee liegt (`climateSeaLevelTemp`, Schnee-, Wald- und Regenphase
    /// bleiben, wie sie in #33 kalibriert sind).
    ///
    /// PHYSIK: die Gleichgewichtslinie (ELA) eines Gletschers liegt bei einer
    /// Jahresmitteltemperatur einige Grad UNTER 0 °C — typisch −2 … −8 °C je nach
    /// Niederschlag (Ohmura et al. 1992: ELA-Temperatur gegen Winterniederschlag,
    /// maritime Gletscher nahe −1 °C, kontinentale −8 °C und kälter) —, während
    /// Schnee schon an der 0-°C-Isotherme dauerhaft liegen bleibt. Bis #174 stand
    /// hier implizit 0 °C: Schneegrenze und Firn-Grenze fielen zusammen.
    ///
    /// ANLASS (#174, `docs/glacier-measurements.md` §L): mit dem dt-invarianten
    /// Eistransport trug der Kamm eine geschlossene Eiskappe (oberste 5 % des
    /// Landes zu 10.3 / 6.2 / 11.1 % flach auf den Seeds 1337 / 42 / 20, Eis
    /// 4.1 / 2.1 / 2.6 % des Landes: Hochflächen mit Wänden statt Gräten), weil
    /// die Kamm-Großform viel mehr Land über der Firn-Grenze trägt als die Welt,
    /// auf der #35 geeicht wurde (5.17 / 2.14 / 3.01 % bei der Generierung statt
    /// ~1.5 %). Die Firn-Grenze des Eises liegt bei
    /// `h = sea + (climateSeaLevelTemp − iceFirnTemp) / climateLapseRate`.
    /// VERWORFEN: die Meeresspiegel-Temperatur auf 13 °C heben — dieselbe
    /// Gleichgewichtslinie, aber das GANZE Klima verschiebt sich mit: Seed 42
    /// ohne jeden Schnee, Seed 20 fast ohne, Waldgrenze und Regenphase wandern.
    ///
    /// 0 °C = Verhalten vor #174 (bit-identisch); die Testwelten der
    /// Mechanik-Wächter, deren Eis an der alten Firn-Grenze 0.573 hängt, pinnen
    /// das (`calibrationIceFirnTemp`). Muss ≤ 0 sein, damit das Eis nie wärmer
    /// entsteht als der Schnee liegt.
    ///
    /// Kalibrier-Logbuch (Produktion, Seeds 1337 / 42 / 20): s. unten.
    public var iceFirnTemp: Double = -2.0
    /// **Lawinen-Abgang des Firns** (Issue #174, `docs/glacier-measurements.md`
    /// §M): Weltsteigung (dy/dx in Welteinheiten mit `RenderContract.heightScale`,
    /// gemessen über `Terrain.macroSlope` des BETTS), ab der die Firn-Zufuhr einer
    /// Zelle nicht mehr liegen bleibt (`Lo`, Anteil 0) und ab der sie ganz abgeht
    /// (`Hi`, Anteil 1); dazwischen glatt (`smoothstep`). Der abgehende Anteil geht
    /// nicht verloren, sondern landet — massen-erhaltend — in der ersten Zelle am
    /// Hangfuß, deren Steigung unter `Lo` liegt (steilster Abstieg über das Bett,
    /// `iceAvalancheMaxRun` Zellen). `Hi <= 0` = aus, bit-identisch zum Stand davor
    /// (`simperf --hash` gleich vor und nach).
    ///
    /// ANLASS: ohne den Abgang trägt jede Zelle über der Eis-Firn-Grenze (≈ 0,65)
    /// Firn, auch eine Gipfelflanke von 60°; das Eis schleift die Gipfel bis knapp
    /// unter die Grenze, und das Gelände staut sich dort zu Tafeln mit Wänden
    /// (Seed 1337: höchster Punkt 0,670 statt 0,752 ohne Eis, harte Decke bei
    /// 0,65–0,66; Seed 20: 0,660 statt 0,727). In der Natur halten Flanken über
    /// 35–45° keinen Firn (Lawinen): Hörner und Grate bleiben eisfrei, und die
    /// Lawinen NÄHREN die Kare darunter. Die frühere Variante „Firn-Abgleiten am
    /// Steilhang 0,03…0,06“ (§L) war bei `iceFirnTemp = 0` gemessen, als die ganze
    /// Kappe das Problem war, und ist nicht dieselbe Mechanik: sie senkte die
    /// Zufuhr, ohne sie umzulagern.
    ///
    /// GEMESSEN (Produktion, Jahr 20.000, dt 1000; höchster Punkt Seed 1337 / 20,
    /// eisfrei 0,7521 / 0,7274; Zackigkeit der obersten 5 %, eisfrei 0,00579 /
    /// 0,00529; Eis in % des Landes):
    ///   aus                             0,6704 / 0,6598 · 0,00537 / 0,00512 · 2,43 / 1,06
    ///   nur eigene Zelle, 0,7/1,2 … 1,4/2,2 (Seed 20)
    ///                                   0,665 … 0,679 — Gipfel bleiben gekappt:
    ///                                   ein Gipfel, dessen Zentraldifferenz ±2 Zellen
    ///                                   sich aufhebt, hat Steigung ≈ 0 und trägt Firn
    ///   Reichweite 1 (Maximum im 3×3), 1,0/1,6
    ///                                   0,7523 / 0,7272 · 0,00741 / 0,00617 · 2,73 / 1,39
    ///   Reichweite 2, 1,0/1,6 (Seed 20) 0,7271 — gleich, aber 13 % weniger Eis
    ///   Reichweite 1, 0,7/1,2           0,752 / 0,727 · 0,00763 / 0,00589 · 1,83 / 0,95
    ///   Reichweite 1, 1,2/1,9           0,7503 / 0,7274 · 0,00729 / 0,00605 · 2,92 / 1,66   ← gewählt
    ///   Reichweite 1, 1,4/2,2           0,7437 / 0,7272 · 0,00684 / 0,00603 · 2,89 / 1,74
    /// 1,2/1,9 (≈ 50°/62° in der Darstellung) als Mitte: 1,0/1,6 hielt etwas mehr
    /// Land über der Grenze (0,81 %), verlor aber im V→U-Diagnostic der Produktion
    /// mehr (§M); 1,4/2,2 kappt die Gipfel wieder leicht (0,7437) und kommt an
    /// die Eisgrenze von 3 % des Landes.
        public var iceAvalancheSlopeLo: Double = 1.2
    public var iceAvalancheSlopeHi: Double = 1.9
    /// Längster Lawinenlauf in Zellen (Sicherung gegen endlose Pfade auf
    /// flach auslaufenden Rücken).
    public var iceAvalancheMaxRun: Int = 40
    /// Reichweite (Zellen) der Steigungsmessung für den abgehenden Anteil: das
    /// Maximum der Makrosteigung im Quadrat dieses Radius um die Zelle. 0 = nur
    /// die eigene Zelle — dann trägt ein Gipfel, dessen Zentraldifferenz ±2
    /// Zellen sich aufhebt, Firn, obwohl alles um ihn steil abfällt.
    public var iceAvalancheReach: Int = 1
    /// Wie oft (Sim-Jahre) die Lawinen-Karte (Ziele und Anteile) aus dem aktuellen
    /// Bett neu gebaut wird. Schritte unter dieser Länge bauen sie einmal je
    /// Schritt (der Zeitraffer-Takt, 15 Jahre), große Schritte alle 15 Jahre
    /// ihrer Teilschritte — die Karte hängt damit an der SIM-ZEIT, nicht an der
    /// Schrittweite.
    public var iceAvalancheRefreshYears: Double = 15
    /// GRUNDUMSATZ des Eises (Jahre) — der Sockel `1/τ` in μ, dieselbe Rolle wie
    /// `snowTurnoverYears` beim Schnee: er hält die Dicke auch bei Dauerfrost
    /// BESCHRÄNKT und ist physikalisch als Sublimation/Kalben besetzt.
    ///
    /// Was er deckelt, ist der ENTARTETE Fall: eine Zelle ohne jedes
    /// Oberflächen-Gefälle kann ihre Zufuhr nicht abführen, und ohne diesen
    /// Sockel wüchse sie unbeschränkt. Mit ihm endet sie bei
    /// `I* = a/μ = iceFirnPerSnowYear · snow · iceTurnoverYears`. Das ist als
    /// HARTE Grenze gedacht, nicht als Arbeitspunkt: der reguläre Lauf bleibt
    /// über den Transport bei 0.07 … 0.26 (`docs/glacier-measurements.md` §B),
    /// also eine Größenordnung darunter. Wächter gegen das Entgleisen über sehr
    /// lange Läufe: `Glacier.testLongRunIceStaysBounded`.
    ///
    /// 4000 Jahre: acht mal träger als die Schneedecke (500) — Eis ist der
    /// langsamere Speicher. GEMESSEN gegen 1000 (n = 384, 50k Jahre,
    /// `docs/glacier-measurements.md` §B/§D): mit 1000 zehrt der Sockel die
    /// Zunge zusätzlich zur Schmelze auf, das Eis fällt bis 50k auf 0.29 % der
    /// Landfläche und die V→U-Kennzahl wird verrauscht (Δb +0.03 … +0.84 ohne
    /// Trend); mit 4000 steht sie über den ganzen Lauf bei Δb +0.22 … +0.30 und
    /// das Eis hält 0.45 %. Der Preis ist die schwächere Notbremse: die
    /// Konstruktions-Grenze liegt damit bei 4.0 Höheneinheiten statt 1.0 — beide
    /// weit über allem Gemessenen, der Wächter prüft deshalb ZUSÄTZLICH eine
    /// empirische Schranke.
    public var iceTurnoverYears: Double = 4000
    /// Zusätzliche Ablations-RATENKONSTANTE des Eises je K über 0 °C
    /// (1/(Jahr·K)) — dieselbe Bauform wie `snowMeltPerKYear` und aus demselben
    /// Grund eine Ratenkonstante statt einer festen Schmelzmenge (dt-Invarianz,
    /// s. dort). Sie setzt die REICHWEITE der Zunge: unterhalb der
    /// Gleichgewichtslinie lebt Eis noch `1/(c·T)` Jahre, und in dieser Zeit
    /// trägt der Transport es `v·τ` weit.
    ///
    /// 0.001 gegen die 0.06 des Schnees, also 60× träger. Das ist KEINE Aussage
    /// über Gradtagsfaktoren (real schmilzt Eis SCHNELLER als Schnee, DDF 5–8
    /// gegen 3–5, Hock 2003) — es ist die Konsequenz der Vorrats-Lesart: μ wirkt
    /// auf den VORRAT, und eine 400-m-Eiszunge trägt ein Vielfaches des Wassers
    /// einer Schneedecke. Dieselbe absolute Schmelzhöhe je Jahr ist damit eine
    /// entsprechend kleinere Rate.
    ///
    /// Gemessen (n = 384, 30k Jahre, `docs/glacier-measurements.md` §C; Reichweite
    /// = Höhenspanne, um die das Eis unter die Firn-Grenze reicht):
    ///   0.004 → Reichweite 0.003 … 0.024, das Eis bleibt im Kar
    ///   0.002 → Reichweite 0.094
    ///   0.001 → Reichweite 0.098 … 0.133   ← gewählt
    ///   0.0004 → Reichweite 0.139, aber die Zunge wird zur Eiskappe (6 % Landanteil)
    public var iceMeltPerKYear: Double = 0.001
    /// Fließ-Basis des Eises, auf n = 640 kalibriert und in `updateIce` mit
    /// `(n−1)²` skaliert — GENAU die Konvention von `hillDiffusion` („kappa je
    /// 100-Jahr-Pass"), damit der Transport wie die Hangdiffusion
    /// auflösungs-unabhängig ist.
    ///
    /// Der Ausstrom einer Zelle je Teilschritt ist `kappa · I · Σ Δs⁺` — also
    /// linear in der Eisdicke (dickeres Eis fließt schneller, Glen-Lesart) und
    /// linear im Oberflächen-Gefälle. Ein KONSTANTES kappa ist die bewusste
    /// Vereinfachung gegen die SIA (`D ∝ H^{n+2}|∇s|^{n−1}`): nur so bleibt der
    /// Teilschritt-Deckel konstant und die Sub-Taktzahl budgetierbar
    /// (`docs/research-climate-cryosphere.md` §4.1).
    ///
    /// 3.0 (250× `hillDiffusion`) — Eis kriecht um Größenordnungen schneller als
    /// Boden. Nach OBEN begrenzt die Rechenzeit: die Sub-Taktzahl ist
    /// `kappa·wMax·dt/iceFlowSubCap` (s. `updateIce`), gemessen kostet der Pass
    /// bei 3.0 auf n = 640 rund +0.8 s für einen `+10.000 Jahre`-Sprung und
    /// +18 ms für einen 500-Jahr-Schritt (`docs/glacier-measurements.md` §E).
    /// Gemessen (30k J., n = 384; Landanteil Eis / Reichweite unter die
    /// Firn-Grenze): 1.0 → 1.41 % / 0.068 · 3.0 → 1.71 % / 0.098 ·
    /// 6.0 → 1.88 % / 0.120. Über 3.0 kauft die doppelte Rechenzeit nur noch
    /// 20 % mehr Reichweite.
    public var iceFlowK: Double = 3.0
    /// Maximale Transport-Zahl EINES Teilschritts (dimensionslos) — der Anteil
    /// einer Eissäule, der sie am STEILSTEN Hang verlassen darf. Legt die
    /// Sub-Taktzahl fest: `nSub = ⌈kappa·max(wMax, 2·I_max)·dt / cap⌉` mit
    /// `wMax` = größte Summe positiver Oberflächen-Abfälle und `I_max` = größte
    /// Eisdicke (beide einmal je Schritt gemessen, s. `updateIce`). Dieselbe
    /// Konstruktion wie die 0.2 der Hangdiffusion in `step()`, nur mit
    /// gemessenem statt angenommenem Gefälle.
    /// 0.25 ist der klassische explizite Deckel des 5-Punkt-Sterns in 2D: bei
    /// `kappa·ΣΔs⁺ ≤ 0.25` verlässt höchstens ein Viertel der Säule die Zelle je
    /// Teilschritt.
    ///
    /// **Die zweite Kennzahl (Issue #174).** Das reicht nicht, damit das Schema
    /// nicht überschwingt: der Fluss `kappa·I·(s_k − s_nb)` ist Diffusion der
    /// Eis-OBERFLÄCHE mit dem Koeffizienten `kappa·I`, und deren Schachbrett-
    /// Modus wächst je Teilschritt um `|1 − 8·kappa·I|`. Dickes Eis auf flachem
    /// Bett (I ≫ ΣΔs⁺) lief deshalb bei großen Schritten instabil — in der
    /// Produktion bei dt = 1000 eine Schachbrett-Oberfläche, die das Bett in
    /// EINEM Schritt im Mittel 0,065 tief schliff (zehn Schritte à 100: 0,005),
    /// und eine Eismasse, die an der Schrittweite hing
    /// (`docs/glacier-measurements.md` §L). Seitdem gilt zusätzlich
    /// `kappa·I ≤ cap/2 = 1/8`, die Grenze, unter der der Modus nicht mehr das
    /// Vorzeichen wechselt. Gemessen gegen `cap/4` konvergiert (Eismasse
    /// < 0,01 % Abweichung), gegen `cap` (also 1/4, gerade noch stabil) nicht:
    /// −6 … −12 % Eismasse.
    public var iceFlowSubCap: Double = 0.25
    /// HARTE Untergrenze der Positivität: mehr als diesen Anteil der Eissäule
    /// darf ein Teilschritt nie abgeben, egal wie steil die Oberfläche steht.
    ///
    /// Im regulären Lauf bindet er NICHT: die Sub-Taktung misst den steilsten
    /// Eis-Hang und hält `kappa·ΣΔs⁺ ≤ iceFlowSubCap = 0.25` (s. `updateIce`),
    /// also unter diesen 0.5. Er bindet genau da, wo diese Messung veralten
    /// kann — die Oberfläche versteilert sich WÄHREND der Teilschritte, etwa
    /// durch einen Spieler-Eingriff. Dieselbe Rolle wie `meltRunoffCapPerRain`:
    /// eine Notbremse für den Sculpt-Fall, nicht ein Regler der Physik.
    public var iceFlowMoveFraction: Double = 0.5
    /// Glaziale Erosionsrate (Vorfaktor des Flux-Modells,
    /// `E = iceErodeK · q^m · S`). Real erodieren Gletscher 1–2 Größenordnungen
    /// schneller als Flüsse (`docs/research-climate-cryosphere.md` §5) — der
    /// Vergleichswert im Repo ist `outletErode`.
    ///
    /// Die EINHEIT ist Höhe je Jahr (`q` und `S` sind dimensionslos bzw. eine
    /// Höhe × Gefälle), der Wert also nicht mit `outletErode` vergleichbar — er
    /// ist GEMESSEN (`docs/glacier-measurements.md` §D, V→U-Kennzahl `b` der
    /// vergletscherten Talstücke gegen denselben eisfreien Referenzlauf,
    /// n = 384, 50k Jahre):
    ///   3e-5 → Δb −0.09 … +0.00   kein Signal: der Abtrag bleibt unter 20 % der
    ///                             vorhandenen Taltiefe, das Eis formt nichts um
    ///   1e-4 → Δb +0.22 … +0.30   ← gewählt, über alle Zeitpunkte gleichsinnig
    ///   3e-4 → Eisfläche bricht auf 0.1 % ein (Gletscher-Buzzsaw: der Abtrag
    ///                             sägt die Gipfel unter die Firn-Grenze und
    ///                             entzieht sich selbst das Nährgebiet)
    /// 1e-4 kostet auf 30k Jahre 0.024 Höheneinheiten Gipfelhöhe gegen den
    /// eisfreien Arm — spürbar, aber genau die erwünschte glaziale Denudation.
    public var iceErodeK: Double = 1e-4
    /// Fluss-Exponent m des glazialen Stream-Power-Gesetzes
    /// `E = K · q^m · S^n`. 0.5 wie bei Liebl et al. 2023 und wie `mExp` im
    /// fluvialen Pendant (`outletIncision`) — die glaziale Rate ist damit ein
    /// FAKTOR auf einer schon kalibrierten Maschinerie statt einer zweiten
    /// Kalibrier-Achse. n = 1 steht fix im Code (dieselbe Wahl wie fluvial).
    public var iceErodeFluxExp: Double = 0.5
    /// Radius der **Schleifspur** in Zellen: über dieses Quadrat wird die
    /// glaziale Erosionsrate gemittelt, bevor sie ins Gelände geht. 0 = aus
    /// (rein lokale Rate, bit-identisch zur Rechnung ohne Ausstrich).
    ///
    /// Das ist die Gegenmaßnahme, die `docs/research-climate-cryosphere.md` §4.3
    /// beim Kauf des Flux-Modells VORHERGESAGT hat — und die Messung hat sie
    /// eingefordert: die lokale Flux-Rate ist im Thalweg am größten und schneidet
    /// dort eine Kerbe, das Querprofil wurde damit V-IGER statt U-iger (V→U 1.447
    /// gegen 1.352 im eisfreien Referenzarm, also die falsche Richtung —
    /// `docs/glacier-measurements.md` §D). Ein Gletscher schleift über seine
    /// ganze BREITE; Liebl et al. 2023 lösen dasselbe Problem im OpenLEM mit
    /// derselben Maßnahme („artificially expanded erosion swath").
    ///
    /// 2 Zellen (5×5-Fenster) — s. Sweep in `docs/glacier-measurements.md` §D.
    /// Fester ZELL-Radius wie `HydraulicParams.erodeRadius`: eine Breite in
    /// Welteinheiten wäre für den Kernel die ehrlichere Größe, aber dann hinge
    /// die Fenstergröße an `n` und mit ihr die Rechenzeit je Zelle.
    public var iceErodeSwathRadius: Int = 2
    /// MORÄNE: Höheneinheiten Sediment je Höheneinheit ausgeschmolzenen Eises.
    /// Das Eis führt eine als konstant angenommene Schuttfracht mit; wo es
    /// abschmilzt, bleibt sie liegen — Ausschmelz-Moräne an Zunge und Rand, dort
    /// wo der Schmelz-Anteil von μ groß ist. Im Akkumulationsgebiet (T ≤ 0) ist
    /// dieser Anteil exakt 0, es entsteht also keine Moräne unter dem Nährgebiet.
    ///
    /// Eine echte Fracht-Buchhaltung (erodiertes Material im Eis mitführen und
    /// stromabwärts ablegen) wäre ein zweites Transportfeld für eine Wirkung, die
    /// dieselbe Form hat: Masse-Erhaltung gilt in diesem Repo ohnehin nicht
    /// (detachment-limited Stream-Power, AGENTS.md). GEMESSEN ist stattdessen das
    /// VERHÄLTNIS Ablagerung zu glazialem Abtrag (`docs/glacier-measurements.md`
    /// §F, n = 256, ein Schritt aus demselben Zustand): bei 0.05 legt das Eis
    /// **20.6 % (dt = 500) bzw. 22.6 % (dt = 5000)** dessen ab, was es abträgt —
    /// der Rest verlässt das System als Schmelzwasserfracht, wie im fluvialen
    /// Pfad auch.
    public var iceMoraineK: Double = 0.05
    /// Ab dieser Eisdicke gilt eine Zelle als VERGLETSCHERT: sie kommt in
    /// `Terrain.underIce`, und die fluvialen Gates greifen (Auslass-Inzision,
    /// Tropfen und der Bett-Funnel `Terrain.erodeCell`/`depositCell` — s.
    /// `Terrain.updateIce`).
    /// 0.002 Höheneinheiten ≙ 8 m bei H_ref = 4000 m: unter einem Schneefeld
    /// dieser Mächtigkeit fließt kein Eis und der Bach läuft normal weiter. Der
    /// Wert hält den Saum der Gletscher schmal — ohne ihn wanderte die Maske mit
    /// dem exponentiellen Ausläufer der Bilanz beliebig weit ins Tal.
    ///
    /// **Eine Schwelle, drei Wirkungen:** Sie gatet nicht nur die fluvialen
    /// Pässe, sondern in `iceFlowSubStep` auch den Eis-TRANSPORT und die
    /// glaziale ABRASION. Sonst wäre der dünne Saum eine Zone, in der beide
    /// Erosionsgesetze gleichzeitig am selben Bett arbeiten — die fluvialen
    /// hängen an `underIce`, das Fließen und die Abrasion hingen anfangs an
    /// „irgendeine positive Restdicke". Die BILANZ (Zufuhr, Schmelze, Moräne)
    /// bleibt bewusst ungegatet: ein Schneefeld muss über die Schwelle wachsen
    /// können. Wächter: `Glacier.testThinIceNeitherFlowsNorGrinds`.
    public var iceMinThickness: Double = 0.002
    /// Sättigungs-Referenz der EIS-Deckung fürs Rendering:
    /// `Deckung = I / (I + iceCoverRef)`, dieselbe Bauform wie `snowCoverRef`.
    /// 0.01 gegen eine Gleichgewichtsdicke von ~0.05: die Zunge ist über ihre
    /// ganze Länge deutlich als Eis lesbar und blendet erst am dünnen Rand aus.
    /// Reiner RENDER-Parameter (`Terrain.iceCover`,
    /// `SimRender.TerrainColorRenderer`) — kein Pass liest ihn.
    public var iceCoverRef: Double = 0.01

    // ---- Klima / Vegetation ----
    // Zeitkonstante der Vegetations-Relaxation, Jahre. Seit Issue #2
    // EXPONENTIELL (`1 − e^(−dt/τ)`, wie der Flood-Kill daneben schon immer):
    // die lineare Form `min(1, dt/τ)` war bei τ = 250 ab dt = 250 J. GESÄTTIGT,
    // ein +2000-Jahre-Sprung setzte `veg` also instantan aufs geografische Ziel,
    // derselbe Zeitraum in 240-Jahr-Schritten dagegen relaxierte (gemessen:
    // Faktor 0.96 je Schritt linear gegen 0.62 exponentiell bei dt = 240).
    // `veg` geht über `vegDamp` in JEDEN Erosionspass ein — der Unterschied
    // wanderte damit direkt ins Relief. Der Wert selbst ist unverändert.
    public var vegTimeConstant: Double = 250

    // ---- Vegetations-Typen (Stufe 2: Gras/Wald/Auwald) ----
    // Die Klassen werden je Zelle aus veg + Flussnähe + Steigung abgeleitet
    // (Terrain.updateVegClass) und verstärken die bestehende 0.6-Erosions-
    // Dämpfung MULTIPLIKATIV: Schutz = 1 − 0.6·typFactor·veg. Gras = 1.0 hält
    // das heutige Verhalten flächendeckend exakt (Kalibrier-Kaskade: die 0.6
    // bleibt unangetastet); nur Wald/Auwald schützen stärker.
    public var vegTypeFactorForest: Double = 1.1   // Wald: Wurzelwerk bindet etwas stärker als Gras. 1.25 drückte im 50k-Vergleichslauf die Ruggedness sichtbar (Rinnen wuchsen zu) → 1.1 als milde Differenzierung.
    public var vegTypeFactorRiparian: Double = 1.3 // Auwald: dichtes Wurzelwerk + Feuchtboden = kohäsivste Ufer (0.6·1.3 = 0.78 < 1, kein Vorzeichenwechsel möglich). Bewusst spürbar über Wald, damit Ufer-Reaches sich von den Hängen abheben.
    // Ufer-Kohäsion der Mäander-Migration: Verschiebung je Knoten × (1 −
    // meanderCohesion · mittleres Auwald-veg im Ufer-Streifen ±meanderBankWidth).
    // 0.5 → voll bewachsene Ufer (Streifen-Mittel ~0.5) migrieren ~25% langsamer,
    // kahle Reaches exakt wie bisher (Faktor 1). 1.0 fror bewaldete Läufe im
    // Kohäsions-Test fast ein (Faktor bis 0.5 auf dem ganzen Lauf) → zu starr,
    // Mäander-Dynamik ist der Kern des Projekts. Die Mäander-Kern-Tests pinnen
    // meanderCohesion = 0 (meanderCfg) und bleiben dadurch unberührt.
    public var meanderCohesion: Double = 0.5

    // ---- Vegetations-Störung + Sukzession (Stufe 3) ----
    // Flood-Kill: steht Wasser tiefer als vegFloodKillDepth, stirbt der Bewuchs
    // mit eigener schneller Zeitkonstante (Wurzelfäule/Ertrinken) statt der
    // trägen 250a-Relaxation. 0.03 = die See-Render-Schwelle (substanzielles
    // stehendes Wasser); seichteres Ponding (überströmte Aue) tötet nicht —
    // das drückt schon das veg-Ziel (hf−h > 0.015 → target 0) über τ=250.
    public var vegFloodKillDepth: Double = 0.03
    public var vegFloodKillYears: Double = 20 // τ_kill: nach ~60 J. (3τ) ist eine geflutete Fläche praktisch kahl. 250 (alte Relaxation) ließ Wälder Jahrhunderte „unter Wasser stehen".
    // Sukzession/Dispersal: Regrünung braucht Samen-Druck — das veg-Ziel wird
    // um max(veg im Umkreis)·Strength angehoben (nur auf BEWOHNBAREN Standorten,
    // geografisches Ziel > 0.05: steile Hänge/Höhenwüste bleiben kahl, kein
    // Spontanwald). Wirkung: Störungsflächen (Flut/Ufer-Kill) neben intaktem
    // Bewuchs regenerieren mit dessen Dichte als Ziel; freistehende Maxima
    // strahlen nur mit 0.75-Abfall je 2-Zellen-Ring aus → begrenzte Säume,
    // keine uniforme Verwaldung (1.0 ließe Wald jede bewohnbare Zelle fluten).
    public var vegDispersalRadius: Double = 2    // Zellen (Chebyshev) — Pass 1 sammelt das Nachbarschafts-Maximum
    public var vegDispersalStrength: Double = 0.75

    // ---- Mäander-Migration (Lagrange-Zentrumslinien) ----
    public var meanderEnabled: Bool = true       // AN: auf dem sanfteren Terrain (baseRelief 0.78) + mit gedeckelter Migration stabil. Läufe wandern, schnüren Altarme ab — der eigentliche Fluss-Dynamik-Wunsch.
    public var meanderMigration: Double = 8.0e-6 // kMig (Produktion, n=640/kein Uplift): laterale Rate ∝ Krümmung×Abfluss. Von 5e-5 gesenkt — bei den großen Produktions-Einzugsgebieten tangelte 5e-5 die Läufe (Sinu-Max 7..26). 8e-6 → hübsche Mäander (Mittel ~2). Die Mäander-Kern-Tests pinnen ihren alten Wert in meanderCfg().
    public var meanderMaxSinuosity: Double = 3.0 // Sinuositäts-Deckel: darüber migriert ein Lauf nicht weiter (Glättung/Cutoff holen ihn zurück) → keine Knäuel-Läufe, Max bleibt beschränkt.
    // #10: GEPRÜFT, unverändert. D8-Zellen über dieser Schwelle (n=832, Seed
    // 1337, aus → an): 31588 → 29439 (Jahr 0, −6.8 %), 36324 → 35326 (5k),
    // 37922 → 36683 (20k), 36244 → 36982 (50k); die daraus gezogenen
    // Zentrumslinien bleiben damit im selben Umfang. Wächter der Mäander-Mechanik
    // pinnen ihre eigene Konfiguration (meanderCfg) und sind unberührt.
    public var meanderMinCells: Double = 85       // ab so viel Einzugsgebiet gilt "Hauptfluss"
    public var meanderNodeSpacing: Double = 1.5   // Ziel-Knotenabstand (Zellen)
    public var meanderNeckDist: Double = 2.0      // Halsbreite für Cutoff (Zellen). Von 1.2 erhöht: Schlingen schnüren früher ab → Sinuosität wird niedriger gedeckelt (weniger Knäuel). Kern-Tests pinnen 1.2 in meanderCfg().
    public var meanderSmooth: Double = 0.12       // milde Laplace-Glättung je Schritt
    /// Der räumliche Cutoff-Index beschleunigt lange Produktionsläufe. Der
    /// Referenzpfad bleibt Standard, weil seine exakte Cutoff-Reihenfolge die
    /// bestehenden Terrain-Metriken kalibriert.
    public var meanderSpatialCutoffIndex = false
    public var meanderFlatSlope: Double = 0.02    // nur unter dieser Steigung mobil (Flachland)
    public var meanderSkew: Double = 0.5          // Downstream-Skew: Anteil upstream-gewichteter Krümmung (0=symmetrisch)
    public var meanderSkewLength: Double = 4.0     // Abkling-Länge der Upstream-Gewichtung (Zellen)
    // ---- Mäander-Grid-Kopplung (M3) ----
    public var meanderCarve: Double = 2.5e-4      // Bett-Inzision entlang der Linie (∝ kSed)
    public var meanderBankErode: Double = 1.2e-4  // Prallhang-Erosion (lateral, massenerhaltend)
    public var meanderBankWidth: Double = 1.6     // Halbbreite Ufer-Versatz (Zellen)
    public var channelErodeDamp: Double = 0.4     // Grid-Stream-Power auf Kanalzellen (Reconciliation)
    // Zeitkonstante der Altarm-Verlandung (gleicht das längere Stream-Map-
    // Gedächtnis aus; Bett steigt zum Rand). Seit Issue #2 EXPONENTIELL
    // (`1 − e^(−dt/τ)` statt `min(1, dt/τ)`): die lineare Form verlandete einen
    // Altarm bei einem +5500-Jahre-Sprung KOMPLETT in einem Schritt, dieselbe
    // Zeit in kleinen Schritten dagegen nur zu 63 % (1 − 1/e). Der Wert ist
    // unverändert — die Wächter `testMeanderOxbowSiltsUp`/`testMeanderOxbowAging`
    // laufen mit dt = 500 (Faktor 0.0909 linear gegen 0.0870 exponentiell,
    // −4.3 %) und bleiben damit im gepinnten Band.
    public var oxbowFillYears: Double = 5500
    public var oxbowMaxAge: Double = 25000        // ab diesem Alter gilt der Altarm als verlandet (aus der Liste)

    // ---- Mäandergürtel (Issue #174, Paket B) ----
    //
    // Vorher (`meanderBelt = false`, bit-identisch erhalten für die
    // Kopplungs-Wächter in `meanderCfg()`): Migration ∝ Krümmung × Abfluss mit
    // positiv gewichteter Stromauf-Krümmung, Ufer-Rückkopplung eine Zelle außen
    // → eine Zelle innen, keine Kanalbreite im Bett. Gemessen
    // (`docs/zielbild-measurements.md`): Wellenlänge 1–4 Kanalbreiten statt
    // 10–14, die Sinuosität kam aus Zacken in Bandbreite; Querprofil verkehrt
    // (außen/innen 0,6–0,8); 900–2000 Hals-Cutoffs je 20.000 Jahre.
    //
    // Mit `meanderBelt`:
    // - Breite `b(Q)` = Band-Breite (`WaterRender.ribbonHalfWidthCells`, EINE
    //   Funktion für Bett und Band), Abfluss entlang des Laufs monoton.
    // - Migration nach Howard–Knutson: lokale Krümmung NEGATIV gewichtet,
    //   stromauf integrierte Krümmung positiv, Kern-Länge ∝ Breite. Kurze
    //   Wellen (unter ~Kernlänge) werden gedämpft, lange wachsen — das wählt die
    //   Mäanderwellenlänge. Rate ∝ Breite × (Breite · Krümmung), sub-getaktet.
    // - Bett über die volle Breite, asymmetrisch (Kolk außen), Material des
    //   Prallhangs als Gleithang-Bank innen, gedeckelt knapp unter bankfull →
    //   laterale Planation, `barAge` als Zustandsfeld.
    // - Hals-Cutoff ab einer Kanalbreite, Chute-Cutoff bei großem Abfluss.
    //
    // Kalibrierung auf dem Produktionsgelände (Issue #174, zweiter PR; Seeds
    // 1337/42/20, Mittel über Jahr 10.000–20.000 bzw. 50.000–100.000, volle
    // Messreihe `docs/zielbild-measurements.md` § Paket B, Kalibrierung):
    // Sinuosität 1,1–1,9 → 1,6–1,7, λ/Breite 4–15 → 9–13, Querprofil-
    // Asymmetrie ~1 → 1,8–2,7. Drei Befunde trugen:
    // 1. Howard–Knutson ist KONVEKTIV instabil: Bögen wachsen beim Wandern
    //    stromab und brauchen 2–3 Wellenlängen Lauf, um aus Rauschen zu
    //    wachsen. Die Tiefland-Abschnitte sind 15–60 Breiten lang mit festen
    //    Enden; dort entstanden nur domänengroße Schleifen oder gerade Linien
    //    (auf einer Ebene, ohne jede Gelände-Kopplung, nachgemessen). Deshalb
    //    ein Stromab-Anteil im Kern (`meanderBeltDownstreamWeight`) und eine
    //    Störquelle (`meanderBeltNoise`).
    // 2. Das Querprofil entstand im Stempel, überlebte den Schritt aber
    //    nicht: Knoten-Knicke kippten es abwechselnd (jetzt Bogen-Krümmung,
    //    `meanderBeltProfileWidths`), die Tropfen gruben jeden Schritt ein
    //    symmetrisches V hinein (jetzt kein Tropfen-Abtrag im Gürtelbett, s.
    //    `Terrain.step`), und die Ablage nur innen ließ den Bezug je Teilschritt
    //    sinken (Sohlen-Ratsche, das Gerinne lag ~2 Tiefen unter der eigenen
    //    Aue; jetzt Ablage über die volle Breite).
    // 3. τ = 150 Jahre ließ das Bett der wandernden Linie um Zellen
    //    hinterherlaufen (`meanderBeltRelaxYears`).
    //
    // Zeitmittel-Abnahme (Issue #174, dritter Schritt; Punkte 9–13 je Seed im
    // Zeitmittel, gewählt auf 24 Seeds, `docs/zielbild-measurements.md`
    // § Paket B — Zeitmittel-Abnahme): sichtbare junge Altarme im Tiefland
    // 1,7 → 4,4 / 4,8 im Mittel, Summe erfüllter Punkte 127 → 182 von 240.
    // Der Gürtel schnürte fast nur Knicke an Spiralkernen ab (unter
    // `WaterRender.oxbowMinimumNodes`, unsichtbar), weil die örtliche
    // Sättigung das Wachstum vor dem Hals-Cutoff stoppte
    // (`meanderBeltSinuosityStart/Full` 2,0/2,8 → 3,0/4,0); dazu
    // `meanderBeltPoolGain` 2,5 → 4, `meanderBeltBrakeDepths` 2 → 3,
    // `meanderBeltPoolSkew` 2,5 → 3 (Begründungen dort).
    public var meanderBelt = true
    /// Gewicht der lokalen Krümmung (Howard–Knutson Ω). Läuft als implizite
    /// Diffusion der Linie (κ = |Ω|·Rate·b²), s. `MeanderState.migrateBeltChannel`.
    public var meanderBeltLocalWeight: Double = -1.0
    /// Gewicht der stromauf integrierten Krümmung (Howard–Knutson Γ).
    /// Zusammen mit dem Stromab-Gewicht 2,0 wie vorher: das Wachstum
    /// σ(k) ∝ k²·((Γ↑ + Γ↓)/(1+(kL)²) − 1) und damit die Wellenlängen-Wahl
    /// hängen nur an der Summe, die Wandergeschwindigkeit stromab an der
    /// Differenz Γ↑ − Γ↓.
    public var meanderBeltUpstreamWeight: Double = 1.2
    /// Gewicht der STROMAB integrierten Krümmung (derselbe Kern gespiegelt) —
    /// der „downstream influence" der Mäandertheorie nahe der Resonanz
    /// (Zolezzi & Seminara 2001). Senkt die Wanderung stromab bei gleichem
    /// Wachstum, die Bögen wachsen am Ort statt aus kurzen Tiefland-Abschnitten
    /// hinauszuwandern. Gemessen (Jahr 20.000, alle Läufe, mit Störquelle,
    /// Kernlänge 1,2): 0 → Sinuosität 1,11 / 1,12 / 1,15, 0,5 (Γ↑ 1,5) → 1,45
    /// / 1,37 / 1,23, 0,8 → 1,73 / 2,60 / 2,02. 1,0 (symmetrisch, keine
    /// Wanderung) verworfen: auf der Ebene Schlingen bis Sinuosität 21.
    public var meanderBeltDownstreamWeight: Double = 0.8
    /// Abkling-Länge des Stromauf-Kerns in Kanalbreiten. Lineare Analyse:
    /// Wachstum σ(k) ∝ k²·(Γ/(1+(kL)²) − 1), am schnellsten bei
    /// (1+(kL)²)² = Γ, also λ ≈ 9,8·L. 1,2 Breiten → λ ≈ 12 Breiten
    /// (Leopold–Wolman 10–14); gemessen ohne Gelände 10–16. Verworfen 3,5: dort
    /// wachsen nur Wellen über 22 Breiten, und die langsam.
    /// Kalibrierung im Gelände: das ist die Wellenlänge ENTLANG des Laufs, die
    /// gemessene (Luftlinie über zwei Halbwellen) ist um die Sinuosität kürzer.
    /// 1,2 → λ/b 9,2 / 10,7 / 11,1 (Jahr 10.000–20.000) und 9,1 / 9,2 / 8,5
    /// (50.000–100.000); 1,5 (mit Rate 0,02, das Wachstum fällt ∝ 1/L²) →
    /// 10,9 / 13,1 / 9,2 und 10,0 / 10,6 / 11,0. 1,8 wuchs zu langsam
    /// (Sinuosität 1,5).
    /// 1,5 → 1,0 mit der Kopplung an die Entwässerung (#187, zusammen mit
    /// `meanderBeltRate` 0,02 → 0,03; 24-Seed-Zeitmittel, Punkte 9–13; die
    /// Reihe unten lief vor der Tropfen-Sperre nur im wandernden Bett): ohne
    /// das Erben wandern nur noch die Läufe mit eigenem Abfluss, und die
    /// Kopplung ersetzt jeden Schritt, was ihr D8-Netz nicht trägt. Mit
    /// 1,5 / 0,02 140 von 240, Sinuosität 1,42 / 1,32; 1,2 / 0,03 177;
    /// 1,0 / 0,03 201; 1,2 / 0,04 197; 1,0 / 0,04 221 (Matrix-Seeds 30 von
    /// 30); Nachbarn 1,0 / 0,05 214, 0,9 / 0,04 216.
    /// Zeitraffer-Korrektur #174: 1,0 → 0,85 bei unveränderter Rate 0,03,
    /// nach zeitbasierter Kopplung und geteilter Profil-Relaxation. Diese
    /// Paarung hält die Auen-Schranke auf Mac und Docker-Linux; Kern 0,9
    /// verfehlt sie auf Linux knapp (0,001579 statt <0,00156). Matrix:
    /// 28/30 Punkte. Rate-Nachbarn 0,0325…0,04 brachten keinen auf beiden
    /// Plattformen tragfähigen Gewinn. Ensemble und dt-Vergleich:
    /// docs/zielbild-measurements.md § Gürtel im Zeitraffer.
    public var meanderBeltKernelWidths: Double = 0.85
    /// Migrationsrate je Jahr: Anteil der Kanalbreite bei `b · eff = 1`.
    /// 0,015 ≈ 1–2 % der Breite je Jahr in engen Bögen (reale Mäanderflüsse:
    /// 1–5 %). 0,005 wuchs im Gelände nicht über die Startzacken der D8-Trasse
    /// hinaus. Messreihen: `docs/zielbild-measurements.md` § Paket B.
    /// 0,02 seit Kernlänge 1,5 (gleiches Wachstum wie 0,015 bei 1,2 auf die
    /// Wellenlänge gerechnet, s. dort). 0,03 bei Kernlänge 1,2: frühere
    /// Cutoffs, Sinuosität FIEL auf 1,06 / 1,01 / 1,24.
    /// 0,02 → 0,03 mit der Kopplung (#187), Messreihe bei
    /// `meanderBeltKernelWidths`. Ohne Kopplung war 0,03 zu schnell (oben);
    /// gekoppelt muss ein Bogen schneller wachsen, als das D8-Netz ihn abkürzt.
    /// Auf dem Endstand (Tropfen-Sperre nur im wandernden Bett): 0,03 → 210
    /// von 240 (Matrix-Seeds 30 von 30), 0,035 → 213 (29), 0,04 → 207 (29).
    /// 0,03, weil jede Erhöhung vor allem mehr Hals-Cutoffs bringt: sichtbare
    /// junge Altarme im Mittel 13,7 / 15,8 / 18,0 (vor #187: 4,4).
    public var meanderBeltRate: Double = 0.03
    /// Störquelle des Kerns (`MeanderState.perturb`): Auslenkung je Knoten
    /// `A · Breite · √(Rate · dt)`, Einheitsvarianz, 0 = aus. Ohne sie spülte
    /// der Kern seine Anfangszacken in ~60.000 Jahren hinaus (Sinuosität 1,00
    /// ab Jahr 62.000 auf drei geraden Läufen); 0,002–0,02 halten ihn bei
    /// Sinuosität ~2 und λ/b 11–13. Allein (ohne Stromab-Anteil) im Gelände
    /// wirkungslos (Sinuosität 1,05–1,35), s. `meanderBeltDownstreamWeight`.
    public var meanderBeltNoise: Double = 0.01
    /// Talwand-Bremse ab so viel Überhöhung des Geländes 3,5 Kanalbreiten weit
    /// in Bewegungsrichtung über der Linie, in Rinnentiefen (`.infinity` = aus).
    /// 2 → 3 mit der Sättigung 3/4 (s. `meanderBeltSinuosityStart`): die
    /// größeren Bögen liefen bei 2 schon an Aue-Stufen fest, der junge Gürtel
    /// überstrich zu wenig (Gürtel/Amplitude im Mittel 10.000–20.000 auf 12
    /// Seeds 2,9 → 4,7, Punkt 11 erfüllt auf 4 → 10 von 12). Allein, mit
    /// der alten Sättigung, war die Bremse kein Hebel (Werte 4 / 8 / aus).
    public var meanderBeltBrakeDepths: Double = 3.0
    /// Nur Läufe ab diesem Abfluss (Zellen Einzugsgebiet) wandern. Kleinere
    /// liegen als D8-Linie fest: jeder Lauf ist eine eigene Zentrumslinie ohne
    /// Anbindung an seinen Vorfluter, und frei wandernde Zubringer kreuzten
    /// gemessen die Hauptläufe als Knäuel. 2000 ≈ Kanalbreite 4 Zellen.
    public var meanderBeltMinCells: Double = 2000
    /// Bankfull-Tiefe in Sim-Höhe je Welteinheit Kanalbreite. 0,0021 ≈
    /// Breite/Tiefe 20 (Mäanderflüsse ~10–30) bei 1 Welteinheit ≈ 100 m und
    /// 1 Sim-Höhe ≈ 2,4 km: 100 m Breite → 5 m Tiefe. Bewusst ein fester
    /// Physik-Wert, nicht aus `RenderContract.heightScale` abgeleitet (dieselbe
    /// Begründung wie bei `channelTargetDepth`).
    public var meanderBeltDepthPerWidth: Double = 0.0021
    /// Wie weit der Kolk zur Außenkurve wandert: Profil
    /// `(1 − η²)(1 + skew·a·η)`, `a = min(1, |Krümmung| · b · Gain)`, nie über
    /// die Bank-Oberkante (ab κ·η < −1 läge das Ziel sonst über bankfull).
    /// 2,5: im scharfen Bogen ist die innere Hälfte Gleithang knapp unter
    /// bankfull, der Kolk liegt bei η ≈ 0,46 mit 1,7 Tiefen (Vorlage E).
    /// Asymmetrie (Mittel 10.000–20.000) 1,5 → 2,5: 1,70 / 2,50 / 1,38 →
    /// 2,41 / 4,01 / 2,14 (bei Kernlänge 1,2).
    /// 2,5 → 3 mit der Sättigung 3/4: Kolk 1,9 statt 1,7 Tiefen bei η ≈ 0,48.
    /// Auf 24 Seeds neutral (Asymmetrie-Mittel 2,87 / 4,53 → 3,00 / 4,19 in
    /// den beiden Fenstern); unter den gleichwertigen Kandidaten der mit den
    /// meisten erfüllten Punkten auf den Matrix-Seeds — das ist Realisierung,
    /// nicht Physik (`docs/zielbild-measurements.md` § Zeitmittel).
    public var meanderBeltPoolSkew: Double = 3.0
    /// `a = min(1, |Krümmung| · b · Gain)`: ab Krümmungsradius / Breite = Gain
    /// ist der Kolk voll ausgebildet. 2,5 → 4 mit der Sättigung 3/4: die Bögen
    /// wachsen jetzt bis zum Hals-Cutoff und sind weiter (größerer Radius),
    /// mit 2,5 fiel die Asymmetrie im Mittel 10.000–20.000 auf 8 Seeds von
    /// 2,01 auf 1,67. Radius/Breite 2–4 ist der typische enge Mäanderbogen
    /// (Hickin & Nanson 1984: Migration am stärksten bei 2–3).
    public var meanderBeltPoolGain: Double = 4.0
    /// Fenster der Bogen-Krümmung für das Querprofil (± Kanalbreiten); 0 = die
    /// Knoten-Krümmung der Migration (±½ Breite). Die trug Knicke bis
    /// |κ|·b = 5 (Radius unter einer halben Breite) und kippte das Profil von
    /// Knoten zu Knoten — im Mittel über die Bögen ein symmetrisches V.
    public var meanderBeltProfileWidths: Double = 1
    /// Zeitkonstante, mit der das Bett auf sein Profil und die Bank auf ihre
    /// Höhe relaxiert (Jahre, exponentiell über `relaxFraction`). Soll klein
    /// gegen die Zeit sein, in der die Linie eine halbe Breite wandert: mit 150
    /// lief das Bett der Linie um Zellen hinterher, am Prallhang lag die
    /// äußere Hälfte HÖHER als die innere. 30 → 10 hob die Kolktiefe außen
    /// direkt nach dem Stempel von 0,65 auf 0,98 Tiefen. Bei der höchsten Rate
    /// (gemessen 0,21–0,31 Zellen/Jahr, Review #187) wandert die Linie eine
    /// halbe Breite (3,2 Zellen) in 10–15 Jahren, also in der Größenordnung von
    /// τ selbst — dort läuft das Bett der Linie weiter knapp hinterher (bis
    /// #187 stand hier fälschlich „~60 Jahre").
    public var meanderBeltRelaxYears: Double = 10
    /// Bankoberkante unter bankfull, als Anteil der Kanaltiefe.
    public var meanderBarTopDepth: Double = 0.15
    /// Breite der Bank-Zone innen neben dem Kanal, in Kanalbreiten.
    public var meanderBarWidths: Double = 0.75
    /// Örtliche Sättigung: der Wachstumsterm blendet zwischen diesen
    /// Sinuositäten (über ±`meanderBeltSinuosityWidths` Kanalbreiten gemessen)
    /// auf 0 aus. Ersetzt im Gürtel den GLOBALEN Deckel `meanderMaxSinuosity`:
    /// der fror den ganzen Lauf ein, sobald er erreicht war (gemessen: Rate 0
    /// ab Jahr 5000) — die Schlingen sollen aber weiter stromab wandern.
    /// Ohne Deckel lag die Sinuosität eines Laufs gemessen bei 2–7.
    /// 2,0 / 2,8 → 3,0 / 4,0 (Zeitmittel-Kalibrierung, #174): ein Bogen, dessen
    /// Hals sich schließt (Omega-Form), hat über ±10 Breiten eine örtliche
    /// Sinuosität über 3. Mit 2,0 / 2,8 stand das Wachstum still, bevor ein
    /// Hals zuging; abgeschnürt wurden fast nur Knicke von 3–5 Breiten
    /// Bogenlänge an Spiralkernen (Median 15 Knoten auf Seed 42 und 20, unter
    /// `WaterRender.oxbowMinimumNodes` = 20, also unsichtbar). Sichtbare junge
    /// Altarme im Tiefland, Mittel über 24 Seeds: 1,7 → 4,4 bzw. 4,8 in den
    /// Fenstern 10.000–20.000 / 50.000–100.000. Ein Krümmungsdeckel im Kern
    /// (|κ|·b ≤ 0,3 / 0,5) unterdrückte die Knicke ebenfalls, aber auch fast
    /// jeden Cutoff (Sinuosität 1,2–1,5): verworfen.
    public var meanderBeltSinuosityStart: Double = 3.0
    public var meanderBeltSinuosityFull: Double = 4.0
    public var meanderBeltSinuosityWidths: Double = 10
    /// Hals-Cutoff ab dieser Halsweite in Kanalbreiten (mindestens `meanderNeckDist`).
    public var meanderBeltNeckWidths: Double = 1.0
    /// Längste Schleife (Bogenlänge in Kanalbreiten), die ein Cutoff abschnürt.
    /// Ein Hals- oder Chute-Cutoff nimmt EINEN Bogen heraus (1–2 Wellenlängen,
    /// ~10–30 Breiten); ohne Grenze schnürte ein Lauf, der seitlich zurück an
    /// seinen Anfang driftete, gemessen fast seine ganze Länge ab und lag
    /// danach als gerade Linie da.
    public var meanderBeltMaxLoopWidths: Double = 150
    /// Chute-Cutoff: Sehne unter so vielen Kanalbreiten …
    public var meanderChuteWidths: Double = 2.0
    /// … bei einer Schleife, die mindestens so oft länger ist als die Sehne …
    public var meanderChuteLoopRatio: Double = 8.0
    /// … und mindestens diesem Abfluss (Zellen Einzugsgebiet).
    public var meanderChuteMinCells: Double = 4000

    // ---- Kopplung Gürtel ↔ D8-Entwässerung (Issue #187) ----
    //
    // Messreihe: `docs/zielbild-measurements.md` § Gürtel und Entwässerung:
    // Avulsion (#187).
    /// Linie und D8-Netz koppeln (`Terrain.coupleBeltToDrainage`): der
    /// Abfluss eines Laufs kommt aus SEINEM D8-Weg (Quelle → Empfänger-Kette
    /// bis zum Zusammenfluss mit einem größeren Fluss, Meer oder See), nicht
    /// mehr als laufendes Maximum über jede Berührung; ein Lauf, der neben
    /// seinem Weg liegt, springt hinein (Avulsion). `false` = Stand vor #187
    /// (3×3-Maximum, laufendes Maximum, Trasse „längster Fließweg zuerst").
    public var meanderBeltCoupling = true
    /// Abstand der Topologie-Prüfung in Sim-Jahren, statt je Aufruf.
    /// Die Prüfung liegt am SCHRITTANFANG, wie im 1000-Jahr-Sprung. Der
    /// Rest reist im Spielstand mit. 0 prüft wie vor der Korrektur je Schritt.
    /// 1000 Jahre bewahren die Phase des bisherigen Sprungs und reduzieren
    /// auf Seed 1337 die zusätzlichen Ersetzungen bei dt 100 (vorher 53.590
    /// gegen 16.106 bei dt 1000 bis 20k). Ohne Profil-Umbau: dt 100 erreicht
    /// mit Kern 1,0 wieder 219/240 statt 165/240 Punkten.
    /// Messreihe: docs/zielbild-measurements.md, § Gürtel im Zeitraffer.
    public var meanderBeltCouplingYears: Double = 1000
    /// Mobile Querprofile hälftig vor und nach den übrigen Geländepässen
    /// relaxieren. Migration und steiler Linien-Abtrag behalten ihre volle
    /// Zeit. Für ein festes Ziel ergeben zwei halbe Expositionen dieselbe
    /// Relaxation wie eine ganze; der zweite Pass migriert nicht erneut.
    /// Der alte große Schritt verlor sein Profil nach dem Stempel an die
    /// Inzision und Hangdiffusion: Matrix-Asymmetrie dt 100/1000 im späten
    /// Fenster 8,21/4,56 → 8,10/7,88 (Kern 0,9). Die globale Pass-Reihenfolge
    /// bleibt erhalten; nur die zweite Profilhälfte liegt vor dem Klima.
    /// Messreihe: docs/zielbild-measurements.md § Gürtel im Zeitraffer.
    public var meanderBeltSymmetricStamp = true
    /// Ein Knoten liegt an seinem D8-Abschnitt, wenn eine Zelle des Abschnitts
    /// höchstens halbe Kanalbreite plus so viele Zellen entfernt liegt: das
    /// Bett überstreicht die volle Breite, der D8-Lauf darin ist eine Treppe
    /// und hängt an der Sohle von gestern. 24-Seed-Zeitmittel (mit Rate
    /// 0,03 / Kern 1,0): 1,5 → 140 (Rate 0,02 / Kern 1,5), 3 → 207, 4 → 201,
    /// 6 → 203; mit Rate 0,04: 3 → 214, 4 → 221. Die Kopplungs-Kennzahl
    /// (Abstand zur D8-Rinne) misst unabhängig davon.
    public var meanderBeltCouplingSlackCells: Double = 4
    /// Avulsion, wenn die Linie ihren D8-Abschnitt über mindestens so viele
    /// Kanalbreiten Bogenlänge verlässt. Kein Kalibrier-Hebel für die Punkte
    /// 9–13: 2 / 4 / 8 Breiten (ohne Überhöhungs-Kriterium, Stand vor der
    /// Neukalibrierung) gaben 146 / 155 / 148 von 240, Sinuosität 1,40–1,46.
    public var meanderBeltAvulsionWidths: Double = 2.0
    /// … oder schon kürzer, wenn das Gelände unter dem abgekoppelten Stück im
    /// Mittel um mehr als so viele Bankfull-Tiefen über dem D8-Abschnitt
    /// dazwischen liegt (überhöhtes Gerinne). `.infinity` = nur das
    /// Längen-Kriterium (0 statt 2 Tiefen: 146 statt 147 von 240).
    public var meanderBeltAvulsionDepths: Double = 2.0
    /// Zeitkonstante der Avulsion (Jahre): solange eine Strecke abgekoppelt
    /// ist, springt der Fluss mit der Rate 1/τ (Wahrscheinlichkeit
    /// `1 − e^(−dt/τ)` je Schritt, deterministisch aus Zeit und Ort). 0 =
    /// sofort bei der ersten Prüfung. Ohne Rate hing die Zahl der Avulsionen
    /// an der Schrittweite: Seed 1337, 8000 Jahre, dt 100 gegen 1000: 204 gegen
    /// 71; mit τ = 1000: 53 gegen 41.
    public var meanderBeltAvulsionYears: Double = 1000
    /// Ein verlassenes Gerinne wird erst ab so vielen Kanalbreiten Bogenlänge
    /// Altarm (kürzere behalten nur die `barAge`-Narbe): ein Stück unter einer
    /// halben Mäanderwellenlänge ist ein Knick, kein Bogen. Ohne Schwelle
    /// (alles ab 4 Knoten) trug Seed 1337 in Jahr 20.000 420 Altarme
    /// (Median 19 Knoten, vor #187: 63, Median 28), und der Wächter gegen
    /// abgeschnürte Knicke (`ZielbildLandformTests`, Median ≥ 20) kippte.
    public var meanderBeltAbandonMinWidths: Double = 5

    // ---- Störung / Regeneration nach Spieler-Eingriffen (Issue #26) ----
    //
    // Ein Pinselstrich ändert `h`, aber die halbe Landschaft hängt an der
    // TOPOGRAFIE, die es gerade noch gab: Vegetation, Stream-Map-EWMA,
    // Mäanderlinien und Altarme. Ohne Behandlung laufen die einfach weiter, und
    // eine exakt flache Platte kommt gar nicht erst ins Erodieren
    // (`outletIncision` überspringt gefällelose Zellen, Tropfen enden bei
    // verschwindendem Gradienten). Gemessen (Seed 1337, n=96, ganze Karte über
    // die echte flatten()-API auf sea+0.25 gezogen, Jahr 3.000):
    // Hochseitenrelief 0.0059, Talseitenrelief 0.0039, Makro-Steigung 0.00066,
    // 91,8 % Wald, 0 % Rinnen — die Waldtapete des Reports. Nach dem Fix:
    // 0.062 / 0.099 / 0.0053 / 88,2 % / 31,6 % Rinnen.
    // Volle Messreihen: `docs/flatten-regeneration-measurements.md`.
    //
    // Die Antwort ist BEWUSST räumlich und zeitlich begrenzt: stark veränderte
    // Zellen tragen einen abklingenden Störungsgrad `disturb` ∈ 0..1, und nur
    // dort greifen die Regenerations-Effekte. Ohne Eingriff läuft alles
    // bit-identisch wie vorher (Wächter `testUntouchedAgingIsBitIdentical`).
    // VERWORFEN als Alternative: den Relief-Servo global stärker fahren — das
    // macht exakt die Alterung aus Issue #13 rückgängig und wirkt auf der
    // ganzen Karte statt auf der Baustelle.
    public var disturbanceEnabled = true
    /// Höhenänderung durch das Werkzeug, ab der eine Zelle als VOLLSTÄNDIG
    /// gestört gilt (Störungsgrad 1). 0.04 ≈ 8 % der frischen Reliefspanne
    /// (n=96, Seed 1337: max−min 0.526).
    ///
    /// Was die Werkzeuge je AUFRUF bewegen (Pinselgewicht w ∈ 0..1, Stärke am
    /// UI-Maximum: der Slider deckelt bei 3, und `Main.gd` skaliert den
    /// Zieh-Strich auf `Stärke · min(Δt, 0.05) · 60`, bei 60 fps also ≈ 3):
    /// * **Einebnen** `(Ziel − h) · min(1, 0.18·Stärke) · w`, also
    ///   0.54·(Ziel − h)·w. Ein Strich über einen Hang mit ≥ 0.074 Höhen-
    ///   differenz (bei vollem w) erreicht die volle Störung SOFORT — genau der
    ///   Fall aus Issue #26. Das Nachziehen einer schon fast passenden Fläche
    ///   bleibt weit darunter; dort soll auch nichts zurückgesetzt werden.
    /// * **Anheben/Absenken** `±0.006·Stärke·w`, also 0.018·w — das bleibt je
    ///   Aufruf UNTER der vollen Störung (≈ 45 % bei w = 1) und summiert sich
    ///   erst über mehrere gehaltene Frames auf. Antippen stört also nur
    ///   teilweise, längeres Modellieren voll.
    /// * **Spitzhacke** `−0.02·Stärke·w²` (Main.gd fährt hier Stärke ×1.5) und
    ///   **Glätten** `(3×3-Mittel − h)·0.30·Stärke·w` liegen dazwischen und
    ///   summieren sich ebenso über die Striche.
    public var disturbanceFullChange: Double = 0.04
    /// Zeitkonstante des Abklingens. 1200 Jahre: nach 3.000 Jahren (2,5 τ) sind
    /// 92 % der Regeneration eingetragen — die Wirkung liegt im beobachtbaren
    /// Fenster, danach übernimmt die normale Physik. Gemessen (Innenfläche,
    /// Jahr 3.000, settle 0.35): τ=800 → Hochseitenrelief 0.0562 / Makro-Steigung
    /// 0.0058, τ=1200 → 0.0527 / 0.0055, τ=2000 → 0.0449 / 0.0047 (dort ist bei
    /// Jahr 3.000 noch ein Viertel der Störung offen, die Fläche also unnötig
    /// lange steril).
    public var disturbanceRecoveryYears: Double = 1200
    /// Anteil des bewegten Materials, der über das Abklingfenster als
    /// **Setzung/Rebound** zurückkommt (0 = aus, 1 = der Eingriff verschwindet
    /// wieder). Frisch aufgeschüttetes Material kompaktiert, entlastetes Gelände
    /// hebt sich — und weil beides der Mächtigkeit der Auffüllung folgt,
    /// schlägt die begrabene Struktur gedämpft wieder durch (differentielle
    /// Kompaktion). Das ist der Haupthebel: die begrabenen Täler werden wieder
    /// zu Tiefenlinien, und die neue Entwässerung hat etwas, dem sie folgen kann.
    ///
    /// Gemessen (Innenfläche, Jahr 3.000, τ=1200, Hochseitenrelief /
    /// Talseitenrelief / Makro-Steigung):
    /// 0.00 → 0.0073 / 0.0054 / 0.00065 · 0.10 → 0.0156 / 0.0230 / 0.0017 ·
    /// 0.25 → 0.0381 / 0.0571 / 0.0039 · **0.35 → 0.0527 / 0.0796 / 0.0055** ·
    /// 0.50 → 0.0767 / 0.1128 / 0.0078.
    /// 0.5 differenziert am stärksten, nimmt dem Werkzeug aber die halbe
    /// Wirkung zurück; 0.25 lässt die Fläche zu lange steril. Wiederholtes
    /// Nachziehen konvergiert geometrisch (der zweite Strich bewegt nur noch
    /// das gesetzte Material, also 35 % von 35 %).
    public var disturbanceSettle: Double = 0.35
    /// Amplitude des Mikro-Reliefs, das eine voll gestörte Zelle über das
    /// Abklingfenster INSGESAMT einträgt (Höheneinheiten, ±).
    ///
    /// Der Symmetriebruch für Flächen, die schon VOR dem Eingriff eben waren —
    /// dort ist die Setzung uniform und erzeugt kein Gefälle. Bewusst NICHT im
    /// Werkzeug selbst: der Soforteffekt des Einebnens bleibt exakt flach
    /// (Wächter `testFlattenIsExactlyFlatImmediately`), das Relief wächst erst
    /// über die folgenden Jahrhunderte hinein.
    ///
    /// Als ALLEINIGER Hebel reicht er nicht — die Hangdiffusion räumt
    /// kurzwelliges Rauschen wieder weg (gemessen ohne Setzung, ganze Karte,
    /// Jahr 3.000: Amplitude 0.012 → Hochseitenrelief 0.0083, 0.030 → 0.0137,
    /// 0.060 → 0.0249). Deshalb klein gehalten: ab ~0.02 wirkt die frische
    /// Fläche körnig statt eben.
    public var disturbanceReliefAmp: Double = 0.012
    /// Grund-Ortsfrequenz des Mikro-Reliefs (1/Zellen), fBm mit 5 Oktaven
    /// darüber. 0.02 gibt Wellenlängen von ~50 Zellen (Einzugsgebiete) bis
    /// ~3 Zellen (Rillen) — beides braucht es: die langen Wellen organisieren
    /// die Entwässerung, die kurzen geben den Tropfen etwas zum Anfassen.
    public var disturbanceReliefFreq: Double = 0.02
    /// Anteil, um den der Störungsgrad das Vegetations-ZIEL drückt (1 = frisch
    /// aufgeschobener Rohboden ist kahl). Der zweite Hebel: kahler Boden
    /// erodiert ohne `vegDamp`-Schutz rund 3× schneller, und der Spieler sieht
    /// eine echte Sukzession statt sofortiger Waldtapete (gemessen,
    /// Innenfläche: Jahr 0 kahl → Jahr 500 zu 60 % Gras → Jahr 1.000 zu 84 %
    /// Wald).
    public var disturbanceVegSuppress: Double = 1.0
    /// Ab diesem Störungsgrad verlieren Mäanderlauf/Altarm ihren Zustand: die
    /// Linien der alten Landschaft haben unter dem neuen Gelände keine
    /// Grundlage mehr. Die Läufe werden danach normal aus der frischen
    /// Entwässerung neu getrasst (`seedMeander`). Gemessen (15.000 J. gealtert,
    /// dann eingeebnet): 14 → 0 Altarme, mittlere Sinuosität 1.665 → 1.274;
    /// ohne den Pfad laufen 14 Altarme bei Sinuosität 1.622 einfach weiter.
    public var disturbanceMeanderDrop: Double = 0.5

    public init() {}

    /// Zellgröße in Welteinheiten: `world / (n - 1)`.
    ///
    /// Der Rückgabewert 0 ist der Sentinel für „keine definierte Schrittweite“ und
    /// deckt zwei getrennte Fälle ab (analog zu `count`):
    /// - `n <= 0` sowie nicht-positive oder nicht-endliche Welten: ungültiges Gitter;
    /// - `n == 1`: gültiges 1-Punkt-Gitter (`count == 1`), das nur keinen
    ///   Punktabstand hat.
    /// `cellSize == 0` ist deshalb KEIN Ungültig-Gate für die Config; wer durch
    /// `cellSize` teilt (z. B. die Pinsel-Iteration in `Terrain`), prüft selbst auf
    /// `> 0`.
    public var cellSize: Double {
        guard n > 1, world.isFinite, world > 0 else { return 0 }
        return world / Double(n - 1)
    }

    /// Gesamtzahl der Gitterpunkte: `n * n`. Für leere Gitter (`n <= 0`) und bei
    /// Überlauf defensiv 0 (verhindert positive Zellzahlen bei negativen `n`).
    /// Anders als `cellSize` bleibt `n == 1` gültig: ein 1×1-Gitter hat genau einen
    /// Punkt, und die Puffer aus `Terrain(allocating:)` müssen zu `idx(i,j)` über
    /// `0..<n` passen.
    public var count: Int {
        guard n > 0 else { return 0 }
        let (prod, overflow) = n.multipliedReportingOverflow(by: n)
        return overflow ? 0 : prod
    }
}

// MARK: - Produktions-Konfiguration (Issue #97)

extension SimConfig {
    /// Die Konfiguration, die in Produktion wirklich läuft: `SimConfig()` plus
    /// die zwei reinen Laufzeit-Schalter. Sie steht als EIN benannter Wert hier,
    /// weil sie vorher in sechs handgepflegten Kopien lag (Brücke,
    /// Mess-Harness, vier Teststellen) — nichts verband sie, und `SimConfig()`
    /// allein war damit eine Konfiguration, die nichts fährt.
    ///
    /// Warum die zwei Schalter nicht einfach Defaults werden: die drei
    /// Konfigurations-Ebenen laufen absichtlich auseinander (AGENTS.md „Drei
    /// Konfigurations-Ebenen"). `hydraulicSkipWaterSpawns` ist NICHT
    /// bit-neutral — er verwirft Ozean-Start-Tropfen ganz und erzeugt damit eine
    /// andere, statistisch gleichwertige Welt-Realisierung (gemessen und in
    /// beide Richtungen gepinnt: `SimCoreTests/PerfFlagAB.swift`, Issue #90).
    /// Die bestehenden Kalibrierungen und Testkonfigs stehen auf dem
    /// Core-Default; als Default hier zöge der Schalter sie alle mit.
    public static var production: SimConfig {
        var config = SimConfig()
        config.enableProductionPerformance()
        return config
    }

    /// Dieselben Laufzeit-Schalter auf eine ANDERE Basis-Config — für
    /// Messreihen, die produktionsnah, aber mit abweichender Auflösung oder
    /// eigenem κ messen (`SimCoreTests/EndorheicEvaporation.swift`). Damit
    /// bleibt das Delta zum Core-Default auch dort eine Ableitung statt einer
    /// siebten Kopie.
    public mutating func enableProductionPerformance() {
        hydraulicSkipWaterSpawns = true
        meanderSpatialCutoffIndex = true
    }

    /// Einlauf der Generierung im Produktionslauf: so viele Jahre echte
    /// Sim-Physik direkt nach dem Aufbau, Uhr danach wieder auf 0 (Begründung
    /// und A/B-Bilder: `Terrain.generate(seed:settleYears:)`, PR #106).
    ///
    /// Kein Config-FELD, weil der Einlauf einmalig zur Generierung wirkt und
    /// nicht im Spielstand weiterlebt — er steht trotzdem HIER, damit die
    /// gesamte Abweichung der Produktion vom Core-Default an einer Stelle
    /// ablesbar ist (`generate`-Default 0: die SimCore-Testwelten bleiben
    /// unverändert). Der Mess-Harness liest ihn bewusst nicht: er fährt seinen
    /// eigenen, getrennt einstellbaren Einlauf über `--warmup`.
    public static let productionSettleYears = 3000.0
}
