import Foundation

/// Alle kalibrierbaren Konstanten des Simulationskerns an einem Ort.
/// Höhen sind normiert (~ -0.3 .. 1.4). Weltkoordinaten in abstrakten Einheiten.
public struct SimConfig: Sendable {
    public var n: Int = 832          // Grid-Auflösung (n × n) — hoch für feines dendritisches Detail
    public var world: Double = 130   // Kantenlänge in Welteinheiten. n und world ZUSAMMEN erhöht (von 640/100): cellSize bleibt ~0.156 → alle auf n=640 kalibrierten Per-Zell-Parameter (Braid-Gates, Droplet-Dichte, kappa-Skalierung) gelten unverändert; die Insel wird einfach ~1.7× größer.
    public var sea: Double = 0.15     // Meeresspiegel (normiert)
    public var floor: Double = -0.3   // tiefster Punkt (Tiefseegraben)

    // ---- Terrain-Generierung ----
    public var baseOctaves: Int = 9    // viele Oktaven → feine Grate bis zur Auflösungsgrenze
    public var baseFreq: Double = 3.5  // Grundfrequenz (× 1/n)
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
    public var kSed: Double = 1.1e-4   // Erodierbarkeit lockeres Sediment (weicher)
    public var sedCoverThresh: Double = 0.01 // ab so viel Sediment gilt "bedeckt"
    public var transportCap: Double = 9.0  // Transportkapazität-Koeffizient (SPACE)

    // ---- Braiding (Verflechtung: zelluläres Bänke-Bauen, Murray & Paola 1994) ----
    // Die einzige Zutat, die dem MFD-Fundament noch fehlt: SUPER-LINEARER Sediment-
    // Transport. Kapazität je MFD-Route qcᵢ = Kb·Q·Sᵢ·fᵢ^m mit m≈2.5 — die Super-
    // Linearität liegt auf der lateralen PARTITION fᵢ (nicht auf Q·S, das übers Netz
    // 3 Dekaden spannt): ein Faden trägt mehr als zwei halbe (2·0.5^m ≈ 0.35) → Fäden
    // scouren sich ein und ziehen mehr Wasser (positive Rückkopplung), während
    // unterversorgte/aufgespreizte Zellen ablagern → MITTELBÄNKE, um die sich der
    // Lauf teilt und wiedervereint.
    public var braidingEnabled: Bool = true
    public var braidMinCells: Double = 120   // Reach-Gate der Braiding-PHYSIK (Render-Schwelle ist separat: renderMinCells)
    public var renderMinCells: Double = 320  // ab so viel Einzugsgebiet (Zellen) wird ein Lauf GEMALT. Bewusst über dem Physik-Gate (User: „zu viele Flüsse"): Braiding wirkt ab 120 weiter, sichtbar sind nur substanzielle Flüsse. Auf der 832er-Map qualifizieren sich sonst absolut mehr Läufe über dieselbe Schwelle.
    public var braidExponent: Double = 2.5   // Partitions-Exponent m (>1 ist die Bänke-bauende Instabilität)
    public var braidCapacity: Double = 5.0e-6 // Kb: weniger Kapazität lässt überlastete Reaches Bänke ablagern (n=256: Insel-Summe 9 vs. 4 ohne Pass)
    public var braidBarHeight: Double = 0.006 // Bänke dürfen so weit über den Wasserspiegel (hf) wachsen → Inseln
    public var braidDispersion: Double = 2.0 // dispersiver MFD-Exponent auf FLACHEN großen subaerischen Läufen (Quinn 1995: Exponent abfluss-abhängig, Terrain.mfdLocalExponent): Hänge konvergieren mit mfdExponent=4 (Look), Braid-Plains spreizen mit 2.0 → Fäden können sich um Bänke teilen, ohne als Sheet-Flow zu zerlaufen (1.3 zerlief)

    // ---- Droplet-Hydraulik-Erosion (carvt feines dendritisches Detail) ----
    public var hydraulicEnabled = true      // Droplet-Erosion statt Grid-Stream-Power+Diffusion
    public var streamRefRate: Double = 0.0025 // Stream-Map-Sättigung (nickmcd): ab dieser reife-gewichteten Tropfen-Besuchsrate (Besuche/Jahr, EWMA) gilt ein Lauf als etabliert (Map ≈ 0.63 bei r0, →1 darüber). Trunk-Raten gemessen ~0.003–0.007/J., Zufallspfade ≪0.001 (reife-gewichtet).
    public var streamMapMemoryYears: Double = 6000 // EWMA-Gedächtnis: bei +2k J. bleibt das etablierte Netz verwandt (Jaccard 0.28 statt 0.20 bei τ=3000), ohne Kurzfrist-Flackern.
    public var hydraulicPerYear = 2.0       // Tropfen je Jahr (sanft → Makro-Grate überleben)
    /// Ozean-Starts haben keinen Anteil an der Landformung, können aber fast die
    /// ganze Tropfen-Lebenszeit verbrauchen. Die Produktionskonfiguration lässt
    /// sie aus; der Core-Default bleibt für bestehende Kalibrierungen unverändert.
    public var hydraulicSkipWaterSpawns = false
    public var outletIncision = true        // Flächen-Stream-Power auf dem Entwässerungsnetz: carvt Täler/Auslässe → Becken entwässern zum Meer, dendritische Rinnen + diskrete Seen (nickmcd-Look) statt einer blassen Flach-Ebene
    public var outletErode: Double = 3.0e-5 // Rate der Auslass-Inzision. 3e-5 gibt feine dendritische Rinnen „über die ganze Oberfläche" ohne Überkämmen (6e-5 überkarvt bei 100k)
    public var hillDiffusion: Double = 0.012 // Hangdiffusion-Basis (Bodenkriechen, D·∇²z) im Droplet-Pfad, RÄUMLICH VARIABEL (hillslopeDiffusion): rundet soil-mantled/sanfte Hänge, lässt hohen steilen Kahlfels scharf → gerundete Landschaft mit einzelnen spitzen Gipfeln (die Ausnahme). Der fehlende Alterungs-Prozess laut LEM-Recherche (docs/research-terrain-aging.md). Auf n=640 kalibriert (auflösungs-skaliert in step()).
    // ---- Auen/Schwemmebenen (Überflutungs-Aggradation) ----
    // Flüsse lagern seitlich Sediment ab und bauen flache Auenböden — die breiten
    // Niedrig-Gradient-Reaches, in denen sie mäandern/verflechten können. Ohne sie
    // sind die Talböden zu schmal (V-Täler) für sichtbare Fluss-Dynamik. Füllt nur
    // tal-nahe Zellen bis knapp über Bett-Niveau → steile Talwände bleiben unberührt
    // (die Berge werden NICHT zugeschüttet). Physisch = Overbank-Deposition.
    public var floodplainEnabled = false // AUS: die per-Zell-Aggradation fügt feine Krusten hinzu (gemessen 2.7× Zerklüftung bei 3000 J.) für unbestätigten Auen-Nutzen → zurückgenommen. Ein glatterer Auen-Ansatz (z. B. diffundierte Deposition oder Tiefland-Generierung) ist offen. Code bleibt als Referenz.
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
    public var puddleFillYears = 800.0      // Zeitkonstante der Pfützen-Verlandung (0 = aus)
    public var puddleLakeCoreCells = 48     // See-Kern-Schwelle der Pfützen-Verlandung (s. fillShallowPonds): eine Wasser-Komponente mit ≥ so vielen TIEFEN Zellen (Tiefe > puddleFillDepth) ist ein SEE — ihr Ufersaum verlandet nicht mehr pauschal (die Säume hoben sich sonst als Ganzes sichtbar an: „wachsender Boden ohne Wasser", 90% der Tiefland-Hebung), sondern nur physisch über Droplet-Deltas. Braid-/Auen-Pfützennetze (Einzelpools ≪ 48 tiefe Zellen) verlanden unverändert — Komponentengrößen-Schwellen (64/400 Zellen) und „berührt einen Pool" kippten dagegen den Braid-Insel-Guard, ein relativer Kern-Anteil (20%) ließ den Problemfall (riesiger Saum, kompakter Kern) durch.
    public var lakeLevelResponseYears = 250.0 // Zeitkonstante des DARSTELLUNGS-Seespiegels (Terrain.waterLevel; 0 = aus, Spiegel = hf). Priority-Flood hebt hf beim Zuschütten des Auslass-Sills INSTANTAN fürs ganze Becken; die Auslass-Inzision schneidet in ~100 J. zurück → Sägezahn, sichtbar als periodisch hüpfende See-/Schwemmflächen (gemessen n=832 Seed 1337, 3000 J.: 17 hf-Sprünge > 0.0005, max 0.006; Quellen Droplets+Braiding+Mäander gemeinsam, Dämpfung einzelner Depositionspfade griff nicht und verschob nur die Kalibrierung). 250 J. drückt die sichtbare Restamplitude der ~100-J.-Sägezähne auf ~1/6 (gemessen via LakeLevelStability), lässt echte Pegeländerungen (Verlanden, neue Seen, +10.000-J.-Sprünge) aber praktisch ungebremst durch.
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
    public var waveRelax: Double = 0.5

    // ---- Klima / Vegetation ----
    public var vegTimeConstant: Double = 250 // Jahre

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
    public var oxbowFillYears: Double = 5500      // Zeitkonstante der Altarm-Verlandung (gleicht das längere Stream-Map-Gedächtnis aus; Bett steigt zum Rand)
    public var oxbowMaxAge: Double = 25000        // ab diesem Alter gilt der Altarm als verlandet (aus der Liste)

    public init() {}

    public var cellSize: Double { world / Double(n - 1) }
    public var count: Int { n * n }
}
