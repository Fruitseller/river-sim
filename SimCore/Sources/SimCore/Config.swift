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

    // ---- Hangprozesse (thermische Erosion / Talus) ----
    public var talus: Double = 0.011   // kritische Höhendifferenz je Zelle
    public var thermalRelax: Double = 0.3
    public var rockCrumble: Double = 0.15 // Fels-Anteil beim Hangrutsch (Basis)

    // ---- Relief-Servo (Anti-Verflachung) ----
    // Ohne Dauer-Tektonik (upliftPer100y = 0) erodiert das Relief über 10k+ Jahre
    // monoton weg → „immer flacher" (User-Beobachtung bei 130k: Rollhügel-Ebene).
    // Der Servo ist die Mitte zwischen beiden User-Anforderungen („Berge wachsen
    // nicht" UND „nicht immer flacher"): Hebung springt NUR an, wenn das Land-
    // Relief unter reliefTarget fällt, proportional zum Defizit (∝ deficit/0.1,
    // gedeckelt bei reliefServoPer100y), entlang des fixen ridged-Tektonik-Felds
    // (dieselben Gebirge wachsen nach, keine neuen). Am Ziel regelt er ab →
    // dynamisches Gleichgewicht statt Runaway (isoHighClamp deckelt zusätzlich).
    public var reliefTarget: Double = 0.55
    public var reliefServoPer100y: Double = 0.0015

    // ---- Tektonik / Isostasie ----
    public var upliftPer100y: Double = 0.0 // KEINE Dauer-Tektonik → Berge wachsen NIRGENDS (auch keine lokalen Grate), sie erodieren nur — wie real ohne aktive Plattengrenze/Vulkanismus. Selbst 0.0015 schob mittlere Grate pro 10k-Klick noch sichtbar hoch (+0.03), obwohl der globale Gipfel erodierte. Hebung nur noch über Sculpting/Events. (War 0.009→0.0015→0.0.) (wie real ohne aktive Plattengrenze/Vulkanismus) statt bei jedem 10k-Schritt hochzuwachsen. 0.009 stockte die Landmasse in 100k um +73% auf (meanLand 0.39→0.68 → sichtbares „Wachsen"); 0.0015 hält die Masse ~flach (0.39→0.42), Relief erodiert sanft (0.76→0.65). Nur so viel Hebung, dass die Insel nicht wegerodiert.
    public var isoHighClamp: Double = 0.90 // Hebung → 0 gegen diese Höhe: deckelt das Relief-Runaway (Berge wuchsen sonst über 100k Jahre bis 1.25, Makro-Form lief weg). 0.90 pinnt Relief/maxH über 100k Jahre aufs junge Niveau (~0.75/0.90) — gratiges Gleichgewicht statt Alterung, ohne dass die Erosion die Berge abträgt (0.85 würde bereits erodieren)
    public var isoLowRange: Double = 0.35   // Senkung → 0 gegen den Boden

    // ---- Küste ----
    public var waveBand: Double = 0.06
    public var waveTalus: Double = 0.002
    public var waveRelax: Double = 0.5

    // ---- Klima / Vegetation ----
    public var vegTimeConstant: Double = 250 // Jahre

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
