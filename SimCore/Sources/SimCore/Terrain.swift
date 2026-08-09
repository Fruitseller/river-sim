import Foundation

/// Der Simulationskern: hält alle Felder und führt die Landschaftsentwicklung
/// aus. Kennt bewusst KEIN Godot — dadurch headless mit XCTest testbar.
///
/// Entwässerung über Priority-Flood (Barnes et al.) → füllt Senken, damit Flüsse
/// bis zum Meer routen; Seen = Zellen mit Füllhöhe > Geländehöhe. Zwei Netze mit
/// strikt getrennten Rollen: **D8/`area`** speist die Erosion, **MFD/`areaMFD`**
/// (Freeman/Quinn) NUR Render und Braiding.
///
/// Pass-Reihenfolge des Produktionspfads (`cfg.hydraulicEnabled`, LEM-Konvention
/// — sie ist nicht beliebig, s. `step()` und docs/research-terrain-aging.md §4):
///
///     Uplift (abklingend U(t), Servo nur als Untergrenze)
///     → Lithologie (Härte/Erodierbarkeit aus der frischen Höhe, Issue #12)
///     → computeFlow (Priority-Flood, D8, MFD)
///     → Mäander (migrate + stamp) → outletIncision → Pfützen/Seen → braidPass
///     → Droplet-Erosion (Hydraulic.erode) + Stream-Map-EWMA → Hangdiffusion
///     → Wave → Vegetation
///
/// Die fluviale Makro-Inzision ist damit `outletIncision` (Flächen-Stream-Power
/// auf dem Entwässerungsnetz, impliziter n=1-Solver in Empfänger-Reihenfolge →
/// unbedingt stabil bei großen Zeitschritten); die feine dendritische Textur
/// legen die Tropfen (`Hydraulic.erode`), gerundet wird über LINEARE
/// Hangdiffusion mit räumlich variablem kappa (`hillslopeDiffusion`) — nicht
/// über Schwellen-Talus. Beide Raten (fluvial und Hang) werden zusätzlich vom
/// **Gesteinsfeld** moduliert (`lithHardness`/`lithErodeK`, Issue #12): harte
/// Bänke tragen Schichtstufen, Mesas und lithologische Knickpunkte.
///
/// Der Nicht-Droplet-Zweig (`hydraulicEnabled = false`, `transportLimited` +
/// `diffusionPass`) ist reiner TESTPFAD, s. Kommentare dort.
public final class Terrain {
    public let cfg: SimConfig
    private let n: Int

    // Kernfelder
    public private(set) var h: [Double]      // Geländehöhe (rock + sed)
    public private(set) var rock: [Double]   // hartes Grundgestein
    public private(set) var sed: [Double]    // lockeres Sediment
    public private(set) var upliftBase: [Double] // tektonisches Feld (±, fix je Terrain)
    public private(set) var rain: [Double]   // Luftfeuchte/Niederschlag
    /// Abfluss-GEWICHT je Zelle (Issue #10) — `rain`, normiert auf sein LANDMITTEL,
    /// über See auf den neutralen Wert 1.0 gesetzt. Leer, solange
    /// `cfg.rainWeightedFlow` aus ist (dann laufen alle Pfade bit-identisch zum
    /// Stand vor Issue #9). Gefüllt am Ende von `computeRain`, verbraucht von
    /// `seedFlowAccumulator` (beide Netze) und den Tropfen-Startpunkten
    /// (`Hydraulic.spawnPosition`). Herleitung: `SimConfig.rainWeightedFlow`.
    public private(set) var rainWeight: [Double] = []
    /// **Lithologie** (Issue #12): Härte-Signal je Zelle, −1 = weichstes …
    /// +1 = härtestes Gestein. Leer, solange `cfg.lithologyEnabled` aus ist (dann
    /// laufen alle Pfade bit-identisch zum Stand vor #12). Zusammengesetzt aus
    /// der stratigraphischen Schichtwelle (hängt an `h` — deshalb wird das Feld
    /// je Schritt in `updateLithology` neu abgeleitet) und dem fixen
    /// Provinz-Rauschen. Herleitung und Kalibrierung: `SimConfig.lithologyEnabled`.
    public private(set) var lithHardness: [Double] = []
    /// Relative Erodierbarkeit je Zelle = `1 − lithContrast · lithHardness`
    /// (Mittel ≈ 1, damit die globale Kalibrierung stehen bleibt). Verbraucht von
    /// `outletIncision`, `Hydraulic.erode` (Fels-Anteil) und `transportLimited`.
    private(set) var lithErodeK: [Double] = []
    /// Referenzhöhe der Schichtebene je Zelle — geneigte Ebene + Faltungs-
    /// Verbiegung, **fix je Seed** (`buildLithologyField`). Die stratigraphische
    /// Koordinate einer Zelle ist `(h − lithBed) / lithLayerThickness`.
    private var lithBed: [Double] = []
    /// Großräumige Härte-Provinzen (−1…1), fix je Seed: Batholith gegen
    /// Sedimentbecken → strukturkontrollierte Entwässerung über ganze Landstriche.
    private var lithProvince: [Double] = []
    public private(set) var veg: [Double]    // Vegetationsdichte 0..1
    /// Vegetations-Klasse je Zelle: 0 kahl · 1 Gras · 2 Wald · 3 Auwald.
    /// ADDITIV zu `veg` (das bleibt Dichte 0..1 für alle bestehenden
    /// Konsumenten): die Klasse differenziert nur den Erosionsschutz
    /// (vegDamp) und die Mäander-Ufer-Kohäsion. Abgeleitet in updateVegClass.
    public private(set) var vegClass: [UInt8]
    /// Flussnähe 0..1 (gedämpfte Dilatation der Wasser-Maske) — Eingangsgröße
    /// der Auwald-Klasse, geglättet, damit die Klassen-Grenzen weich bleiben.
    private var riparian: [Double]
    private var vegScratch: [Double] // Pingpong-Puffer der Riparian-Dilatation
    /// Erosionsschutz-Faktoren je Klasse ([kahl, Gras, Wald, Auwald], aus cfg):
    /// Schutz = 1 − 0.6·Faktor·veg — die 0.6-Basiskalibrierung bleibt fix.
    private let vegTypeFactor: [Double]

    // Entwässerung
    public private(set) var hf: [Double]     // gefüllte Oberfläche (Priority-Flood)
    /// Darstellungs-SEESPIEGEL: folgt `hf` ratenbegrenzt (`lakeLevelResponseYears`).
    /// Priority-Flood setzt `hf` INSTANTAN aufs Sill-Niveau — jede Deposition am
    /// Becken-Auslass (Droplets, Braiding, Mäander; gemessen: keine Einzelquelle
    /// dominiert) lässt sonst die GESAMTE Seefläche im Render schlagartig springen
    /// und die Auslass-Inzision schneidet sie über ~100 J. wieder frei (Plug/
    /// Breach-Sägezahn). Physisch: ein See füllt/leert sich mit endlicher Rate.
    /// NUR fürs Rendering — die gesamte Physik (Pools, Verlandung, Tropfen)
    /// liest weiter `hf` (ein träges Verlandungs-Ziel war messbar wirkungslos
    /// und störte die Braid-Bänke, s. Kommentar in fillShallowPonds).
    public private(set) var waterLevel: [Double]
    /// BILANZ-Seespiegel abflussloser Becken (Issue #11): die Höhe, auf die der
    /// Wasserhaushalt (Zufluss gegen Verdunstung) das Becken dieser Zelle
    /// deckelt. Persistenter Zustand — der Ziel-Stand wird je Schritt neu
    /// gerechnet, der WEG dorthin ist ratenbegrenzt (`endorheicResponseYears`),
    /// und das Gedächtnis dafür steht hier. Für Zellen ohne verdunstungs-
    /// limitiertes Becken ist es einfach der Füllstand `hf` (bzw. veraltet, s.
    /// `capEndorheicBasins`: der Wert wird beim Wiedereintritt geklemmt).
    private var lakeBalance: [Double]
    /// Becken-Rolle je Zelle aus dem Wasserhaushalt (Issue #11):
    /// * 0 — kein verdunstungs-limitiertes Becken (Normalfall: See läuft bis zur
    ///   Sill über, exakt das Verhalten vor #11)
    /// * 1 — trockengefallener Beckenboden (Playa: Wasser stand hier, bis die
    ///   Bilanz den Spiegel gesenkt hat)
    /// * 2 — Wasserfläche eines abflusslosen Beckens = **terminale Senke**: das
    ///   Wasser verlässt sie nur über die Verdunstung, nicht über die Sill
    ///   (`receiver` = −1, kein MFD-Überlauf, keine Auslass-Inzision)
    public private(set) var endorheicBasin: [UInt8]
    /// Salzkruste 0..1 — Verdunstungsrückstand auf trockengefallenem
    /// Beckenboden, EWMA mit `endorheicSaltYears`. NUR Rendering
    /// (SimNode.terrainColorBytes malt die helle Kruste) und Vegetations-Ziel
    /// (Salzpfannen sind kahl); keine Erosionsphysik.
    public private(set) var saltCrust: [Double]
    /// Gemessener ZUFLUSS des Beckens je Zelle (Abfluss-Einheiten wie `area`) —
    /// nur in verdunstungs-limitierten Becken gesetzt, sonst 0. Er wird auf der
    /// VOLLSTAND-Entwässerung gemessen (Pass 1 in `floodAndRoute`) und ist im
    /// fertigen `area` nicht mehr ablesbar: dort ist die Seefläche eine terminale
    /// Senke. Für Diagnose/Wächter (`testBasinWaterAreaMatchesTheBudget`).
    public private(set) var endorheicInflow: [Double]
    /// Ziel-Maske der Salzkruste: trockengefallener Beckenboden, auf dem
    /// SUBSTANZIELL Wasser stand (Vollstand-Tiefe > `endorheicSaltMinDepth`).
    /// Bewusst enger als `endorheicBasin == 1`: der Priority-Flood flutet den
    /// ganzen flachen Beckenboden, ein Millimeter-Saum ist aber keine Salzpfanne
    /// (gemessen n=256/Seed 1337: 9788 trockengefallene Zellen, davon nur ein
    /// Bruchteil je über der Render-Seetiefe).
    private var playaBed: [Bool]
    private var basinSeen: [Bool]   // Arbeitspuffer der Becken-Komponentensuche
    private var basinCells: [Int32] // Zellen des aktuellen Beckens (Bilanz-Sortierung)
    private var basinSlots: [Int32] // deren Plätze in `order` (lokale Umsortierung)
    private var orderPos: [Int32]   // Umkehrabbildung zu `order` (nur beim Deckeln gefüllt)
    public private(set) var receiver: [Int32] // Abfluss-Nachbar (-1 = Senke/Meer)
    /// Einzugsgebiet (Single-Flow/D8 → Erosion). Ohne `cfg.rainWeightedFlow`
    /// reine Zellflächen; mit Schalter (Produktion) ABFLUSS = Fläche ×
    /// normiertes Regen-Gewicht (s. `seedFlowAccumulator`, `updateRainWeight`).
    /// Die SKALA ist in beiden Fällen dieselbe — das Gewicht hat Landmittel 1.
    public private(set) var area: [Double]
    /// Multi-Flow-Einzugsgebiet (Freeman) → NUR Render/Braiding, nie Erosion.
    /// Dieselbe Gewichtung wie `area` (s. `seedFlowAccumulator`).
    public private(set) var areaMFD: [Double]
    private var order: [Int32]               // Pop-Reihenfolge (aufsteigende Füllhöhe)
    private var floodParent: [Int32]

    private var heap: MinHeap
    private var visited: [Bool]
    private var scratch: [Double] // Arbeitspuffer für die Diffusion
    private var qs: [Double]      // Sedimentfracht in Transit (transport-limitiert)
    /// Zellen unter einer Mäander-Zentrumslinie (M3-Maske). Reconciliation-Maske für
    /// BEIDE Erosionspfade: `transportLimited` (Grid) und `Hydraulic.erode` (Droplet).
    private(set) var isChannel: [Bool]
    /// nickmcd-Stream-Map: zeitgemittelte Tropfen-Pfade. Wo Wasser WIRKLICH
    /// fließt — scharfe Fäden statt dispergierter Abflussfläche. Koppelt zurück
    /// in die Droplets (weniger Verdunstung auf etablierten Läufen → River
    /// Sharpening) und ist die Render-Maske für Flüsse. Werte 0..1.
    ///
    /// WICHTIG für dt-Invarianz: gemittelt wird die lineare Besuchs-RATE
    /// (`streamRate`, Besuche/Jahr — Erwartungswert unabhängig von der
    /// Schrittweite); die Sättigung auf 0..1 passiert erst NACH der Mittelung.
    /// Sättigung vor der Mittelung machte die Map dt-abhängig (ein Einzelbesuch
    /// saturierte bei kleinen Schritten sofort → Zufallspfade so hell wie Flüsse).
    public private(set) var streamMap: [Double]
    private var streamRate: [Double] // EWMA der Besuche/Jahr
    private var trackBuf: [Double]   // je Schritt: Tropfen-Besuchszahl je Zelle
    private var pondSeen: [Bool]     // Arbeitspuffer der Pfützen-Komponentensuche
    private var noise: SimplexNoise

    /// **Störungsgrad** je Zelle 0..1 (Issue #26): wie stark hat ein Werkzeug
    /// diese Zelle zuletzt umgegraben — und wie viel Regeneration steht noch
    /// aus. Wird von `applyDelta` (dem gemeinsamen Trichter ALLER Pinsel)
    /// aufgebaut und in `regenerateDisturbed` exponentiell abgebaut. Solange er
    /// > 0 ist, gilt die Zelle als frische Baustelle: kein Bewuchs-Standort,
    /// Mikro-Relief wächst hinein, Mäanderzustand der alten Landschaft fällt weg.
    public private(set) var disturb: [Double]
    /// **Offenes Regenerations-Budget** je Zelle (Höheneinheiten, ±): die
    /// Geländeänderung, die der Regenerations-Pfad noch eintragen wird. Gefüllt
    /// beim Eingriff (Setzung/Rebound des bewegten Materials + Mikro-Relief),
    /// abgearbeitet in `regenerateDisturbed` mit derselben Zeitkonstante wie
    /// `disturb`. Ein einziges Budget-Feld statt „Effekt je Schritt neu
    /// ausrechnen": so teleskopiert die Summe über beliebige Schrittweiten exakt
    /// (Framerate-Invariante).
    private var regenPending: [Double]
    /// Schnell-Ausstieg: ohne je gesetzten Störungsgrad wird der gesamte
    /// Regenerations-Pfad übersprungen → normale Alterung bit-identisch zum
    /// Stand vor #26 (Wächter `testUntouchedAgingIsBitIdentical`).
    private var disturbActive = false

    /// Wandernde Fluss-Zentrumslinien (Mäander-Migration). In M2 noch entkoppelt
    /// vom Höhenfeld: sie evolvieren mit der Zeit, formen `h` aber noch nicht
    /// (das macht `meanderStamp` ab M3).
    public private(set) var meander = MeanderState()

    public private(set) var years: Double = 0
    private var seed: UInt32
    private var stepCount: UInt32 = 0 // deterministischer Zähler für die Droplet-Seeds
    private var flowStepCount: UInt32 = 0

    public init(config: SimConfig = SimConfig(), seed: UInt32 = 1337) {
        self.cfg = config
        self.n = config.n
        self.seed = seed
        self.mfdMinA = config.braidMinCells * config.cellSize * config.cellSize
        self.mfdFlatCell = config.meanderFlatSlope * config.cellSize
        let c = config.count
        h = .init(repeating: 0, count: c)
        rock = .init(repeating: 0, count: c)
        sed = .init(repeating: 0, count: c)
        upliftBase = .init(repeating: 0, count: c)
        rain = .init(repeating: 0, count: c)
        veg = .init(repeating: 0, count: c)
        vegClass = .init(repeating: 0, count: c)
        disturb = .init(repeating: 0, count: c)
        regenPending = .init(repeating: 0, count: c)
        riparian = .init(repeating: 0, count: c)
        vegScratch = .init(repeating: 0, count: c)
        vegTypeFactor = [1, 1, config.vegTypeFactorForest, config.vegTypeFactorRiparian]
        hf = .init(repeating: 0, count: c)
        waterLevel = .init(repeating: 0, count: c)
        lakeBalance = .init(repeating: 0, count: c)
        endorheicBasin = .init(repeating: 0, count: c)
        saltCrust = .init(repeating: 0, count: c)
        endorheicInflow = .init(repeating: 0, count: c)
        playaBed = .init(repeating: false, count: c)
        basinSeen = .init(repeating: false, count: c)
        basinCells = []
        basinSlots = []
        orderPos = .init(repeating: 0, count: c)
        receiver = .init(repeating: -1, count: c)
        area = .init(repeating: 0, count: c)
        areaMFD = .init(repeating: 0, count: c)
        order = .init(repeating: 0, count: c)
        floodParent = .init(repeating: -1, count: c)
        visited = .init(repeating: false, count: c)
        scratch = .init(repeating: 0, count: c)
        qs = .init(repeating: 0, count: c)
        isChannel = .init(repeating: false, count: c)
        streamMap = .init(repeating: 0, count: c)
        streamRate = .init(repeating: 0, count: c)
        trackBuf = .init(repeating: 0, count: c)
        pondSeen = .init(repeating: false, count: c)
        heap = MinHeap(capacity: c)
        noise = SimplexNoise(seed: seed)
        generate(seed: seed)
    }

    @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { j * n + i }

    // MARK: - Datenparallelität

    private static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    /// Führt `body(lo, hi)` über disjunkte Index-Bereiche parallel aus. Nur für
    /// Pässe, deren Zellen unabhängig sind (jede schreibt ausschließlich ihren
    /// eigenen Index) — das Ergebnis ist BIT-IDENTISCH zur sequenziellen Schleife.
    /// Mehr Chunks als Kerne, damit concurrentPerform die ungleich schnellen
    /// P-/E-Kerne auslasten kann.
    @inline(__always) private func parallel(_ count: Int, _ body: (Int, Int) -> Void) {
        let chunks = min(count, max(1, Terrain.coreCount * 4))
        if chunks <= 1 { body(0, count); return }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            body(count * c / chunks, count * (c + 1) / chunks)
        }
    }

    // MARK: - Terrain-Generierung

    public func generate(seed: UInt32) {
        self.seed = seed
        self.years = 0
        self.stepCount = 0
        self.flowStepCount = 0
        noise = SimplexNoise(seed: seed)

        // Tektonik-Feld: fix je Terrain (reale Tektonik wechselt nicht alle 100 J).
        let uNoise = SimplexNoise(seed: seed ^ 0x5eed)
        var uRnd = Mulberry32(seed: seed ^ 0x5eed)
        let uox = uRnd.next() * 1000, uoy = uRnd.next() * 1000
        let uFreq = cfg.upliftFreq / Double(n)
        // Positiv vorgespannt: da detachment-limited Stream-Power Material ins Meer
        // austrägt (nicht massenerhaltend), muss die Tektonik die Landmasse netto
        // tragen — sonst erodiert/senkt die Insel über 100k+ Jahre zu Graten weg.
        for j in 0..<n {
            for i in 0..<n {
                // RIDGED Tektonik: Hebung konzentriert sich auf Gebirgs-GRATE (statt
                // eines glatten Blobs). Entscheidend gegen die Langzeit-Degradation —
                // die Erosion läuft sonst ins glatte Hebungsfeld (→ runde Kuppeln);
                // ein gratiges Hebungsfeld trägt langfristig gratige Berge.
                let ridge = uNoise.ridged01(Double(i) * uFreq + uox,
                                            Double(j) * uFreq + uoy, octaves: 5)
                upliftBase[idx(i, j)] = ridge * 1.15 - 0.22 // Grate → stark hoch, Täler → leicht runter
            }
        }

        // --- Per-Seed-Makro-Parameter: jeder Seed bekommt eine eigene Insel-Form,
        // Reliefstärke, Grat/Rundhügel-Charakter und Küsten-Archetyp → echte Vielfalt
        // statt immer derselben zentrierten Rund-Insel. Deterministisch (Mulberry32).
        var gr = Mulberry32(seed: seed ^ 0x1234_abcd)
        let box = gr.next() * 1000, boy = gr.next() * 1000        // Noise-Region (Seed sampelt anderswo)
        let cx = Double(n - 1) / 2
        let ccx = cx + (gr.next() - 0.5) * 0.34 * Double(n)        // Insel-Zentrum versetzt
        let ccy = cx + (gr.next() - 0.5) * 0.34 * Double(n)
        let aAng = gr.next() * .pi                                  // Anisotropie-Achse
        let aRatio = 0.55 + gr.next() * 1.05                        // Streckung: 0.55 langer Zug … 1.6 gestaucht
        let fStart = 0.58 + gr.next() * 0.30                        // Landausdehnung (kleine Insel ↔ Kontinent)
        let fWidth = 0.18 + gr.next() * 0.26                        // Küstensaum-Breite
        let relief = cfg.baseRelief * (0.80 + gr.next() * 0.45)     // Reliefstärke variiert
        let roll = gr.next() * gr.next() * 0.7                      // 0=schroffe Grate … Rundhügel (quadr.→meist schroff)
        let mFreqK = 0.22 + gr.next() * 0.42                        // Massiv-Frequenz (Berg-Klumpung)
        let mBias = 0.38 + gr.next() * 0.26                         // Tiefland-Grundhöhe
        let bfMul = 0.72 + gr.next() * 0.75                         // Feature-Skala (grob ↔ fein)
        let sharp = 1.0 + gr.next() * 0.9                           // Grat-Schärfe (pow-Exponent)
        let archetype = Int(gr.next() * 3.0)                        // 0 Insel · 1 Küste · 2 Archipel
        let coastAng = gr.next() * 2 * .pi                          // Küsten-Richtung (Archetyp 1)

        @inline(__always) func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }

        // Grundrelief: RIDGED-Multifractal (scharfe Grate), optional mit fBm gemischt
        // (Rundhügel), moduliert vom Massiv-Feld, mit per-Seed variierendem Insel-/
        // Küsten-/Archipel-Falloff unter den Meeresspiegel.
        let bf = cfg.baseFreq / Double(n)
        let ca = cos(aAng), sa = sin(aAng)
        for j in 0..<n {
            for i in 0..<n {
                let x = Double(i) * bf * bfMul + box, y = Double(j) * bf * bfMul + boy
                let ridge = noise.ridged01(x, y, octaves: cfg.baseOctaves)
                let rollv = noise.fbm01(x, y, octaves: 6)          // sanfte Alternative
                let base = (1 - roll) * ridge + roll * rollv       // Grat ↔ Rundhügel
                let massif = noise.fbm01(x * mFreqK, y * mFreqK, octaves: 3)
                let m = mBias + (1 - mBias) * massif               // Gebirge vs. Tiefland
                // Anisotroper, versetzter Falloff.
                let dx = Double(i) - ccx, dy = Double(j) - ccy
                let rx = dx * ca + dy * sa
                let ry = (-dx * sa + dy * ca) * aRatio
                let d = (rx * rx + ry * ry).squareRoot() / cx
                var falloff = 1 - smooth(fStart, fStart + fWidth, d)
                if archetype == 1 {                                // Küste: Land auf einer Seite
                    let proj = (Double(i) - cx) * cos(coastAng) + (Double(j) - cx) * sin(coastAng)
                    let wob = (noise.fbm01(x * 0.6 + 30, y * 0.6 + 30, octaves: 3) - 0.5) * 0.5
                    let g = proj / Double(n) + wob
                    falloff = min(falloff, 1 - smooth(0.0, 0.26, g))
                } else if archetype == 2 {                         // Archipel: in Inseln zerlegen
                    let isl = noise.fbm01(x * 0.7 + 50, y * 0.7 + 50, octaves: 4)
                    falloff *= smooth(0.34, 0.52, isl)
                }
                let ridgeE = 0.38 + 0.62 * pow(base, sharp)        // Talboden angehoben → Täler bleiben Land
                h[idx(i, j)] = ridgeE * relief * m * falloff
            }
        }
        // Pre-Erosion (runevision-Filter): verzweigte Rinnen/Grate einmalig ins
        // Basisrelief carven — deterministisch je Seed (Rinnen-Muster wandert mit).
        if cfg.preErodeEnabled {
            ErosionFilter.apply(h: &h, n: n, sea: cfg.sea,
                                seedOffsetX: box, seedOffsetY: boy,
                                params: cfg.preErodeParams)
        }
        initLayers()
        // Gesteinsfeld (Issue #12) VOR dem ersten Flow: der Becken-Breach und die
        // Spin-up-Tropfen sollen die Härtekontraste schon sehen — die antezedente
        // Entwässerung ist damit von Anfang an strukturkontrolliert.
        buildLithologyField()
        updateLithology()
        // Becken-Wasserhaushalt (Issue #11) im Gleichgewicht starten: die
        // Generierung ruft `computeFlow` mit dt = 0, der Bilanz-Spiegel snappt
        // also auf seinen Zielstand statt sich über die ersten Spieljahre
        // einzuschwingen (dieselbe Doktrin wie `waterLevel = hf` unten).
        for k in 0..<cfg.count {
            lakeBalance[k] = h[k]
            endorheicBasin[k] = 0
            saltCrust[k] = 0
            disturb[k] = 0 // frisches Terrain hat keine Baustellen (Issue #26)
            regenPending[k] = 0
        }
        disturbActive = false
        computeFlow()
        if cfg.breachEnabled { breachBasins() }
        spinUpStreamMap()
        // Die Spin-up-Tropfen lagern Sediment ab und können frisch entwässerte
        // Becken wieder andämmen → einmal nachbreachen (billig, fast alles offen).
        if cfg.breachEnabled { breachBasins() }
        // Vegetation im eingeschwungenen Zustand starten.
        updateVegetation(years: 10000)
        seedMeander()
        waterLevel = hf // Startzustand: Seespiegel = Füllstand (kein Einschwingen)
        // Playas starten mit ihrer Kruste (sie sind ÄLTER als das Spieljahr 0) —
        // sonst salzt eine seit der Generierung trockene Pfanne erst über die
        // ersten ~1200 Jahre ein.
        for k in 0..<cfg.count where playaBed[k] { saltCrust[k] = 1 }
    }

    /// Seespiegel sofort auf den Füllstand setzen — für Spieler-Eingriffe
    /// (sculpt → recomputeFlow): deren Feedback soll instantan sein, nur die
    /// Sim-Dynamik (Plug/Breach am Auslass) ist träge.
    public func snapWaterLevel() { waterLevel = hf }

    /// Initialisiert die Stream-Map bei der Generierung (sonst wären am Anfang
    /// keine Flüsse sichtbar, bis genug Sim-Schritte Tracks akkumuliert haben):
    /// ein paar Tropfen-Chargen laufen das frische Terrain hinab und hinterlassen
    /// die ersten zeitgemittelten Pfade.
    private func spinUpStreamMap() {
        for k in 0..<cfg.count { streamRate[k] = 0; streamMap[k] = 0 }
        guard cfg.hydraulicEnabled else { return }
        let density = Double(n * n) / (640.0 * 640.0)
        for round in 0..<4 {
            for k in 0..<cfg.count { trackBuf[k] = 0 }
            let drops = max(200, Int(2000 * density))
            // Diese Charge entspricht so vielen Jahren Tropfen-Budget:
            let dtEq = Double(drops) / max(1e-9, cfg.hydraulicPerYear * density)
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: seed &+ UInt32(0x9e37 + round), floor: cfg.floor,
                            p: cfg.hydraulic,
                            seaLevel: cfg.hydraulicSkipWaterSpawns ? cfg.sea : nil,
                            hf: hf, receiver: receiver,
                            stream: streamMap,
                            rainWeight: rainWeight,
                            erodibility: lithErodeK,
                            track: &trackBuf)
            for k in 0..<cfg.count {
                streamRate[k] = 0.5 * streamRate[k] + 0.5 * (trackBuf[k] / dtEq)
            }
            deriveStreamMap()
        }
        computeFlow() // die Spin-up-Tropfen haben h leicht verändert
    }

    /// Spin-up der Becken-Entwässerung (nickmcd-Verhalten: Seen entwässern zum
    /// Meer statt vollzulaufen). Lässt die Auslass-Inzision die Sillen der
    /// geschlossenen Becken durchschneiden, BEVOR die Landschaft sichtbar wird —
    /// physisch antezedente Täler. Nutzt bewusst denselben getesteten
    /// `outletIncision`-Pass wie der Sim-Loop; MFD wird im Spin-up übersprungen
    /// (nur fürs Rendering nötig) und am Ende einmal frisch berechnet.
    ///
    /// **Ohne Becken-Wasserhaushalt (Issue #11).** Der Spin-up misst seinen
    /// Fortschritt am See-Anteil (`lakeStats`) — mit gedeckelten Spiegeln SIEHT er
    /// die Becken nicht mehr, bricht nach der ersten Runde ab und lässt genau die
    /// geschlossenen Becken stehen, die er durchschneiden soll (gemessen n=832
    /// Seed 1337 mit Deckel IM Spin-up: 87684 trockengefallene Zellen bei der
    /// Generierung — mehr als die GESAMTE Ponding-Fläche des gebreachten Terrains,
    /// 41648 Zellen; die sichtbare Seefläche fiel von 2.61 % auf 1.04 %).
    /// Physisch sind das auch zwei verschiedene Zeitebenen: der Breach ist die
    /// ANTEZEDENTE Entwässerungsgeschichte (älter als die Landschaft), der
    /// Wasserhaushalt das heutige Klima. Der Deckel kommt deshalb erst im
    /// abschließenden `computeFlow`.
    private func breachBasins() {
        // Routing zuerst OHNE Deckel neu aufbauen: sonst schneidet die erste
        // Inzisionsrunde auf dem gedeckelten Netz des vorigen computeFlow, und
        // die Generierung hinge doch am Klima (der Spin-up soll über alle κ
        // bit-identisch laufen).
        floodAndRoute(dt: 0, applyBalance: false)
        for _ in 0..<cfg.breachMaxRounds {
            let s = lakeStats()
            let land = Double(landCellCount())
            // Fertig, wenn der See-Anteil klein ist UND kein einzelner See mehr
            // dominiert (diskrete nickmcd-Seen statt Zentralbecken).
            if s.fraction < cfg.breachTargetLakeFrac && Double(s.largest) < 0.025 * land { break }
            outletIncision(dt: cfg.breachDT, minAreaCells: 100)
            floodAndRoute(dt: 0, applyBalance: false) // s. Doku: Breach ist verdunstungs-blind
        }
        computeFlow() // hier snappt der Bilanz-Spiegel auf seinen Zielstand
    }

    /// pow() ist im 3.3M-Aufrufe-Hot-Loop von computeFlow teuer; die MFD-
    /// Exponenten sind aber Ganzzahlen (4 dendritisch, 2 dispersiv) →
    /// Multiplikations-Schnellpfad, generischer pow nur als Fallback.
    @inline(__always) private func powFast(_ s: Double, _ p: Double) -> Double {
        if p == 4.0 { let s2 = s * s; return s2 * s2 }
        if p == 2.0 { return s * s }
        // KEIN 0.5→sqrt-Schnellpfad: libm-pow(x, 0.5) weicht bei Laufzeit-Exponent
        // in ~0,14% der Fälle um 1 ulp von sqrt ab (gemessen; Literal-Tests täuschen,
        // weil LLVM pow(x, 0.5) selbst zu sqrt faltet) → nicht bit-identisch, und
        // die 1-ulp-Differenz divergiert übers chaotische System messbar.
        return pow(s, p)
    }

    /// Leitet die 0..1-Stream-Map aus der geglätteten Besuchs-Rate ab.
    /// Rationale Sättigung rate/(rate+r0) statt 1−exp(−rate/r0): gleiche Form
    /// (0.5 bei r0, →1 darüber), aber ohne 409k exp()-Aufrufe je Schritt.
    private func deriveStreamMap() {
        let r0 = cfg.streamRefRate
        for k in 0..<cfg.count {
            streamMap[k] = streamRate[k] / (streamRate[k] + r0)
        }
    }

    /// Diagnostik zum Becken-Wasserhaushalt (Issue #11): Zahl der verdunstungs-
    /// limitierten (abflusslosen) Becken sowie ihre Wasser- und Trockenfläche in
    /// Zellen. `basins` zählt zusammenhängende Komponenten (8er, wie die
    /// Becken-Erkennung selbst) von `endorheicBasin != 0` — ein Becken mit
    /// Restsee UND trockenem Saum ist EINS.
    public func endorheicStats() -> (basins: Int, water: Int, dryBed: Int) {
        var water = 0, dryBed = 0
        for k in 0..<cfg.count {
            if endorheicBasin[k] == 2 { water += 1 } else if endorheicBasin[k] == 1 { dryBed += 1 }
        }
        guard water + dryBed > 0 else { return (0, 0, 0) }
        var seen = [Bool](repeating: false, count: cfg.count)
        var stack = [Int]()
        var basins = 0
        for start in 0..<cfg.count where endorheicBasin[start] != 0 && !seen[start] {
            basins += 1
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            while let k = stack.popLast() {
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if endorheicBasin[nb] != 0 && !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
        }
        return (basins, water, dryBed)
    }

    /// See-Diagnostik: Anteil der Landzellen mit stehendem Wasser (hf−h > `depth`)
    /// und größte zusammenhängende Seefläche (4er-Nachbarschaft, in Zellen).
    /// depth 0.01 = jedes Ponding; 0.03 = nur Seen, die der Renderer auch zeigt.
    public func lakeStats(depth: Double = 0.01) -> (fraction: Double, largest: Int) {
        var wet = 0, land = 0
        var isLake = [Bool](repeating: false, count: cfg.count)
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            land += 1
            if hf[k] - h[k] > depth { wet += 1; isLake[k] = true }
        }
        var seen = [Bool](repeating: false, count: cfg.count)
        var largest = 0
        var stack = [Int]()
        for start in 0..<cfg.count where isLake[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0
            while let k = stack.popLast() {
                size += 1
                let i = k % n, j = k / n
                if i > 0 && isLake[k-1] && !seen[k-1] { seen[k-1] = true; stack.append(k-1) }
                if i < n-1 && isLake[k+1] && !seen[k+1] { seen[k+1] = true; stack.append(k+1) }
                if j > 0 && isLake[k-n] && !seen[k-n] { seen[k-n] = true; stack.append(k-n) }
                if j < n-1 && isLake[k+n] && !seen[k+n] { seen[k+n] = true; stack.append(k+n) }
            }
            largest = max(largest, size)
        }
        return (land == 0 ? 0 : Double(wet) / Double(land), largest)
    }

    // MARK: - Lithologie (räumlich variable Erodierbarkeit, Issue #12)

    /// Baut die **fixen** Anteile des Gesteinsfelds: die geneigte, gefaltete
    /// Schichtebene (`lithBed`) und die Härte-Provinzen (`lithProvince`). Beide
    /// hängen ausschließlich am Seed → gleicher Seed, gleiches Feld (Wächter:
    /// `Lithology.testFieldIsDeterministicPerSeed`).
    ///
    /// Eigener Noise-/PRNG-Zweig (`seed ^ 0x1170`), damit die Lithologie NICHT mit
    /// Relief (`seed`) oder Tektonik (`seed ^ 0x5eed`) korreliert: sonst läge jede
    /// harte Bank auf einem Grat und das Feld wäre nur eine zweite Lesart der
    /// Topografie, statt sie zu formen. Streichrichtung und Fallen variieren je
    /// Seed (wie die Makro-Parameter der Insel in `generate`).
    ///
    /// Sequenzielle Schleife: läuft einmal je Generierung, nicht je Schritt.
    private func buildLithologyField() {
        guard cfg.lithologyEnabled else {
            lithBed = []; lithProvince = []; lithHardness = []; lithErodeK = []
            return
        }
        let c = cfg.count
        if lithBed.count != c {
            lithBed = .init(repeating: 0, count: c)
            lithProvince = .init(repeating: 0, count: c)
            lithHardness = .init(repeating: 0, count: c)
            lithErodeK = .init(repeating: 1, count: c)
        }
        let lNoise = SimplexNoise(seed: seed ^ 0x1170)
        var lr = Mulberry32(seed: seed ^ 0x1170)
        let lox = lr.next() * 1000, loy = lr.next() * 1000
        let dipAng = lr.next() * 2 * .pi
        // Fallen 0.4…1.6 × cfg.lithDip: manche Seeds sind fast flach gelagert
        // (Tafelberge/Mesas), andere deutlich verkippt (Cuestas/Schichtkämme).
        let dip = cfg.lithDip * (0.4 + 1.2 * lr.next())
        let dx = cos(dipAng) * dip / Double(n - 1)
        let dy = sin(dipAng) * dip / Double(n - 1)
        let warpFreq = 2.2 / Double(n)   // Faltungs-Wellenlänge ~ halbe Karte
        let provFreq = 1.6 / Double(n)   // Provinz-Wellenlänge ~ halbe Karte
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let x = Double(i), y = Double(j)
                let warp = lNoise.fbm01(x * warpFreq + lox, y * warpFreq + loy, octaves: 3) * 2 - 1
                lithBed[k] = x * dx + y * dy + warp * cfg.lithWarp
                // fBm nutzt seine [-1,1]-Spanne nie aus (Oktaven mitteln sich weg)
                // → gedehnt und geklemmt, damit es echte Provinz-EXTREME gibt.
                let prov = lNoise.fbm01(x * provFreq + lox + 500, y * provFreq + loy + 500,
                                        octaves: 3) * 2 - 1
                lithProvince[k] = min(1, max(-1, prov * 1.8))
            }
        }
    }

    /// Leitet Härte und Erodierbarkeit aus der **aktuellen** Höhe ab.
    ///
    ///     s     = (h − lithBed) / lithLayerThickness     stratigraphische Koordinate
    ///     Welle = glattes Wechselprofil über s           −1 Bandmitte … +1 Bandgrenze
    ///     hard  = (1−Mix)·Welle + Mix·Provinz + Bias     geklemmt auf [−1, 1]
    ///     K     = 1 − lithContrast·hard                  Erodierbarkeit (Mittel ≈ 1)
    ///
    /// Dass `s` an `h` hängt, IST der Mechanismus: die harte Bank bleibt auf ihrem
    /// Höhenniveau liegen, während die Erosion das weiche Gestein darunter
    /// ausräumt — die Kante wandert seitwärts (Schichtstufen-Rückverlegung), nicht
    /// nach unten. Ein an die Zelle geheftetes, höhen-UNABHÄNGIGES Feld kann das
    /// nicht: dort erodiert die weiche Zelle einmal tief und ist fertig.
    ///
    /// Das Profil ist bewusst polynomial (Dreieck + Smoothstep) statt `sin`: der
    /// Pass läuft je Zeitschritt über alle Zellen (n=832 → 692k), 692k `sin`
    /// kosten pro Schritt ~14 ms Frame-Budget, die Polynom-Variante nichts
    /// Messbares. Die Form ist dieselbe (Mittel 0, weiche Bandgrenzen).
    /// Per-Zelle unabhängig (liest h/lithBed/lithProvince, schreibt nur
    /// lithHardness/lithErodeK) → datenparallel bit-identisch.
    private func updateLithology() {
        guard cfg.lithologyEnabled, lithBed.count == cfg.count else { return }
        let thick = max(1e-9, cfg.lithLayerThickness)
        let mix = min(1, max(0, cfg.lithProvinceMix))
        let bias = cfg.lithHardBias
        let contrast = cfg.lithContrast
        let cnt = cfg.count
        h.withUnsafeBufferPointer { hb in
        lithBed.withUnsafeBufferPointer { bb in
        lithProvince.withUnsafeBufferPointer { pb in
        lithHardness.withUnsafeMutableBufferPointer { hdb in
        lithErodeK.withUnsafeMutableBufferPointer { kb in
            let ph = hb.baseAddress!, pbed = bb.baseAddress!, pprov = pb.baseAddress!
            let phard = hdb.baseAddress!, pk = kb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let s = (ph[k] - pbed[k]) / thick
                    let frac = s - s.rounded(.down)          // Phase im Paket 0..1
                    let tri = abs(2 * frac - 1)              // Dreieck: 1 an der Bandgrenze
                    let sm = tri * tri * (3 - 2 * tri)       // Smoothstep → weiche Kontakte
                    let wave = 2 * sm - 1                    // −1 … +1, Mittel 0
                    var hard = (1 - mix) * wave + mix * pprov[k] + bias
                    hard = min(1, max(-1, hard))
                    phard[k] = hard
                    // Untergrenze 0.05: kein Nullteiler-artiger „unerodierbarer"
                    // Fels, auch wenn lithContrast > 1 gefahren wird.
                    pk[k] = max(0.05, 1 - contrast * hard)
                }
            }
        }}}}}
    }

    private func initLayers() {
        let sedInit = 0.02
        for k in 0..<cfg.count {
            sed[k] = min(sedInit, max(h[k] - cfg.floor, 0))
            rock[k] = h[k] - sed[k]
        }
    }

    // MARK: - Klima (orographischer Niederschlag, Wind von Westen)

    public func computeRain() {
        let nn = n, sea = cfg.sea
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeMutableBufferPointer { rb in
        let ph = hb.baseAddress!, prain = rb.baseAddress!
        // Jede Zeile ist ein unabhängiger West→Ost-Sweep → zeilenparallel.
        parallel(nn) { jLo, jHi in
        for j in jLo..<jHi {
            var m = 1.0
            let k0 = j * nn
            var hs = ph[k0] <= sea ? sea : ph[k0]
            for i in 0..<nn {
                let k = k0 + i
                if ph[k] <= sea {
                    m = min(1, m + 0.015) // über Wasser auftanken
                    prain[k] = m
                    hs = sea
                    continue
                }
                prain[k] = m
                // Anstieg auf GEGLÄTTETER Höhe (EWMA ~4 Zellen): seit der Pre-
                // Erosion trägt jeder Hang feine Rinnen — als Roh-Anstiege gezählt
                // trockneten sie die ganze Insel aus (Regen ≈ 0 → kein Grün).
                // Orographie = Makro-Relief, nicht Rinnen-Textur.
                let hsNew = hs + 0.25 * (ph[k] - hs)
                let uph = max(0, hsNew - hs)
                hs = hsNew
                // Floor 0.18 (war 0.05): auch der Regenschatten-Osten bekommt
                // Grundfeuchte → moosige Tiefland-Ebenen statt kahler Blässe.
                m = max(0.18, m - m * (0.0012 + uph * 1.5))
            }
        }
        }
        }}
        updateRainWeight()
    }

    /// Baut `rainWeight` aus dem frischen `rain` (Issue #10).
    ///
    ///     w[k] = rain[k] / mittleres Land-rain   (Land)
    ///     w[k] = 1.0                             (See)
    ///
    /// Zwei Eigenschaften, auf denen die ganze Rekalibrierung ruht:
    /// 1. **Σw über Land = Zahl der Landzellen** (per Konstruktion des Mittels) —
    ///    der Gesamtabfluss bleibt exakt der der ungewichteten Akkumulation, alle
    ///    in ZELLEN kalibrierten Gates behalten ihre Bedeutung, und die
    ///    Auflösungs-Abhängigkeit des Regen-Landmittels (0.563 bei n=192 …
    ///    0.364 bei n=832) fällt heraus.
    /// 2. **See = 1.0 = das Landmittel**, also der neutrale Wert: die
    ///    Tropfen-Ablehnungs-Stichprobe zieht damit denselben Anteil Starts aufs
    ///    Meer wie ungewichtet (bei `hydraulicSkipWaterSpawns` = derselbe
    ///    Tropfen-Etat auf Land). Für die Akkumulation ist der See-Wert egal —
    ///    Seezellen sind Senken und reichen nichts weiter.
    ///
    /// Das Landmittel wird SEQUENZIELL summiert (feste Reihenfolge → bit-genau
    /// reproduzierbar); die Division je Zelle ist per-Zelle unabhängig und
    /// deshalb parallel bit-identisch. Ohne Land (alles überflutet) bleibt das
    /// Feld neutral bei 1.0.
    private func updateRainWeight() {
        guard cfg.rainWeightedFlow else {
            if !rainWeight.isEmpty { rainWeight = [] }
            return
        }
        let cnt = cfg.count, sea = cfg.sea
        if rainWeight.count != cnt { rainWeight = .init(repeating: 1, count: cnt) }
        var sum = 0.0, land = 0
        for k in 0..<cnt where h[k] > sea { sum += rain[k]; land += 1 }
        let mean = land == 0 ? 0 : sum / Double(land)
        guard mean > 1e-9 else {
            rainWeight.withUnsafeMutableBufferPointer { $0.update(repeating: 1) }
            return
        }
        let inv = 1 / mean
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rb in
        rainWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prain = rb.baseAddress!, pw = wb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi { pw[k] = ph[k] > sea ? prain[k] * inv : 1.0 }
            }
        }}}
    }

    // MARK: - Vegetation

    public func updateVegetation(years: Double) {
        let f = min(1, years / cfg.vegTimeConstant)
        // Flood-Kill (Stufe 3): eigene, schnelle Zeitkonstante. Exponentiell
        // exakt (1 − e^(−dt/τ)) statt linear gedeckelt: bei τ = 20a ist schon
        // ein Zeitraffer-Schritt (dt ≈ 9..240 J.) fast vollständig — die
        // exakte Form hält kleine und große Schritte konsistent.
        let fKill = 1 - exp(-years / cfg.vegFloodKillYears)
        let killDepth = cfg.vegFloodKillDepth
        // Sukzession (Stufe 3), Pass 1: Samen-Druck = max(veg) im Dispersal-
        // Umkreis → vegScratch. Liest nur veg, schreibt nur vegScratch[k]
        // → parallel bit-identisch (Pass1/Pass2-Muster wie hillslopeDiffusion).
        let dispersal = cfg.vegDispersalStrength
        let dr = max(0, Int(cfg.vegDispersalRadius.rounded()))
        let nn = n, sea = cfg.sea
        if dispersal > 0 && dr > 0 {
            veg.withUnsafeBufferPointer { vb in
            vegScratch.withUnsafeMutableBufferPointer { sb in
                let pveg = vb.baseAddress!, psc = sb.baseAddress!
                parallel(nn) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<nn {
                            var m = 0.0
                            for dj in max(0, j - dr)...min(nn - 1, j + dr) {
                                for di in max(0, i - dr)...min(nn - 1, i + dr) {
                                    m = max(m, pveg[dj * nn + di])
                                }
                            }
                            psc[j * nn + i] = m
                        }
                    }
                }
            }}
        }
        // Störungs-Unterdrückung (Issue #26): frisch umgegrabener Rohboden ist
        // kein Standort. Ohne aktive Störung ist das Feld exakt 0 und der
        // Faktor exakt 1.0 → bit-identische Arithmetik zum Stand vor #26.
        let disturbSuppress = cfg.disturbanceEnabled ? cfg.disturbanceVegSuppress : 0
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        rain.withUnsafeBufferPointer { rnb in
        vegScratch.withUnsafeBufferPointer { scb in
        saltCrust.withUnsafeBufferPointer { slb in
        disturb.withUnsafeBufferPointer { dsb in
        veg.withUnsafeMutableBufferPointer { vb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let prain = rnb.baseAddress!, pseed = scb.baseAddress!
            let psalt = slb.baseAddress!, pdist = dsb.baseAddress!
            let pveg = vb.baseAddress!
            // Schreibt nur veg[k] → zeilenparallel, bit-identisch.
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
                    // Flood-Kill: tief überflutet → schneller Absterbe-Pfad
                    // statt Relaxation. Auwald steht am tiefsten und säuft
                    // zuerst ab, dann Wald — emergent aus der Topografie.
                    if phf[k] - ph[k] > killDepth {
                        pveg[k] -= pveg[k] * fKill
                        continue
                    }
                    var target = 0.0
                    let v = ph[k]
                    if v > sea + 0.005 && v < 0.68 && phf[k] - ph[k] <= 0.015 {
                        // Steigung grob (±2 Zellen): der Hang-Charakter entscheidet über
                        // Bewuchs, nicht die feine Rinnen-Textur der Pre-Erosion (sonst
                        // gilt jede Zelle als steil → kahle Täler).
                        let slope = (abs(ph[k + 2] - ph[k - 2]) + abs(ph[k + 2 * nn] - ph[k - 2 * nn])) * 0.125
                        let slopeOk = max(0, 1 - slope * 40)
                        let wet = min(1, prain[k] * 1.3)
                        let altOk = v < 0.5 ? 1 : max(0, 1 - (v - 0.5) / 0.18) // Wald wächst höher
                        target = slopeOk * wet * altOk
                        // Sukzession: Samen-Druck hebt das Ziel NUR auf bewohnbaren
                        // Standorten (geografisches Ziel > 0.05) — steile Hänge und
                        // Höhenwüste bleiben kahl, kein Spontanwald auf kargen Inseln.
                        if dispersal > 0 && target > 0.05 {
                            target = max(target, pseed[k] * dispersal)
                        }
                        // Salzpfanne (Issue #11): der Verdunstungsrückstand eines
                        // ausgetrockneten abflusslosen Beckens ist ein kahler
                        // Standort — sonst begrünt der flache, tief liegende
                        // Beckenboden sofort (flach + Grundfeuchte = hohes Ziel).
                        // Wirkt NUR über saltCrust, das außerhalb solcher Becken
                        // exakt 0 ist → für alles andere unverändert.
                        target *= 1 - psalt[k]
                        // Baustelle (Issue #26): der Störungsgrad drückt das Ziel
                        // gegen 0 und klingt aus → sichtbare Sukzession auf der
                        // frischen Fläche statt sofortiger Waldtapete. Außerhalb
                        // von Eingriffen ist pdist exakt 0.
                        if disturbSuppress > 0 && pdist[k] > 0 {
                            target *= max(0, 1 - disturbSuppress * pdist[k])
                        }
                    }
                    pveg[k] += (target - pveg[k]) * f
                }
            }
            }
        }}}}}}}
        updateVegClass()
    }

    /// Vegetations-Schutzfaktor der Erosionspässe: (1 − 0.6·typFactor·veg).
    /// Die 0.6-Basiskalibrierung bleibt unangetastet (Kalibrier-Kaskade); die
    /// Klassen-Faktoren verstärken sie nur multiplikativ (Gras 1.0 = Status quo,
    /// Wald/Auwald schützen stärker). Max-Produkt 0.6·1.3 = 0.78 < 1.
    @inline(__always) func vegDamp(_ k: Int) -> Double {
        max(0, 1 - 0.6 * vegTypeFactor[Int(vegClass[k])] * veg[k])
    }

    /// Leitet die Vegetations-Klasse je Zelle ab (0 kahl · 1 Gras · 2 Wald ·
    /// 3 Auwald). Auwald = flussnah + flach + feucht: Flussnähe kommt aus einer
    /// gedämpften 3×3-Max-Dilatation (3 Runden, Abfall 0.65/Ring → Werte 1.0 /
    /// 0.65 / 0.42 / 0.27) der Wasser-Maske (substanzielle Läufe `area` ≥
    /// braidMinCells ODER stehendes Wasser hf−h > 0.02). Die Maske liest
    /// bewusst das D8-Netz (`area`), NICHT `areaMFD`: vegClass geht über
    /// `vegDamp` in die Erosion ein, und MFD darf laut AGENTS.md nur Render und
    /// Braiding speisen. D8 konzentriert den Abfluss auf eine Zellspur — die
    /// Ufer-Breite kommt ohnehin aus der Dilatation, nicht aus der Maskenbreite.
    ///
    /// Gehölz sitzt am UFER, nicht im BETT: die Maskenzellen selbst (der
    /// Wasserlauf) bleiben Gras, egal wie dicht `veg` dort ist. Sie mit einer
    /// Gehölz-Klasse zu belegen hieß, Wurzel-Kohäsion auf das Gerinne und den
    /// Talboden zu legen — der Talboden panzerte sich, stehen gebliebene
    /// Knubbel im MFD-Lauf zählten als „Inseln" (Messung Aug 2026:
    /// `testBraidingBuildsBars` zählte im Arm OHNE Braiding-Pass 19 → 31 Inseln
    /// über 12 Seeds, obwohl dort nie ein Bänke-Pass lief; der Braiding-Arm
    /// blieb bei 36 → 37). Gras (Faktor 1.0) heißt: auf dem Gerinne gilt exakt
    /// die Vor-Merge-Dämpfung 1 − 0.6·veg.
    /// Alle Eingangsgrößen
    /// sind glatt (veg relaxiert über τ=250a, riparian fällt über Ringe ab,
    /// Steigung ±2 Zellen) → weiche Klassen-Übergänge statt Flickenteppich.
    /// Determinismus: jeder Pass liest nur fremde Puffer und schreibt
    /// ausschließlich seinen eigenen Index → parallel bit-identisch.
    private func updateVegClass() {
        let nn = n, sea = cfg.sea, cnt = cfg.count
        let cellArea = cfg.cellSize * cfg.cellSize
        let minA = cfg.braidMinCells * cellArea
        // Pass 1: Wasser-Quellmaske → riparian.
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        area.withUnsafeBufferPointer { ab in
        riparian.withUnsafeMutableBufferPointer { rb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pa = ab.baseAddress!, prip = rb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let water = phf[k] > sea
                        && (pa[k] >= minA || phf[k] - ph[k] > 0.02)
                    prip[k] = water ? 1.0 : 0.0
                }
            }
        }}}}
        // Pass 2: 3 Dilatationsrunden (riparian ↔ vegScratch).
        for _ in 0..<3 {
            dilateDamped(from: riparian, to: &vegScratch)
            swap(&riparian, &vegScratch)
        }
        // Pass 3: Klassen. Der 2er-Rand bleibt kahl (wie in updateVegetation,
        // die dort auch kein veg aufbaut).
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeBufferPointer { vb in
        riparian.withUnsafeBufferPointer { rb in
        vegClass.withUnsafeMutableBufferPointer { cb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pveg = vb.baseAddress!, prip = rb.baseAddress!
            let pcls = cb.baseAddress!
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
                    var cls: UInt8 = 0
                    let v = pveg[k]
                    if ph[k] > sea + 0.005 && v >= 0.12 {
                        let slope = (abs(ph[k + 2] - ph[k - 2]) + abs(ph[k + 2 * nn] - ph[k - 2 * nn])) * 0.125
                        // Auwald: bis ~2 Zellen vom Wasser (riparian ≥ 0.4),
                        // flach (etwas toleranter als die Baum-Maske) und nicht
                        // selbst tief überflutet. Sonst: dichter Bewuchs = Wald,
                        // Rest = Gras. Kahl nur bei v < 0.12 (steil/hoch/nass
                        // drückt schon das veg-Ziel auf 0 — die Klasse folgt).
                        //
                        // GEHÖLZ (Wald UND Auwald) ist eine UFER-, keine
                        // BETT-Klasse: die Quellmaske-Zellen SELBST sind der
                        // Wasserlauf, und ein Flussbett trägt kein Gehölz.
                        // Nach der Dilatation gilt `riparian == 1` exakt für die
                        // Maskenzellen (dst = max(src, 0.65·maxNb) hält 1.0 und
                        // hebt Nicht-Masken-Zellen auf höchstens 0.65) — das
                        // identifiziert das Bett ohne Zusatzpuffer. Dieselbe
                        // Doktrin wie meanderStamp, das die Bett-Vegetation
                        // wegreißt (testMeanderStampKillsBedVegetation).
                        //
                        // Bett → Gras (Faktor 1.0) und NICHT Wald (1.1): Gras
                        // ist exakt die Vor-Merge-Dämpfung (1 − 0.6·veg), d. h.
                        // auf dem Gerinne bleibt die alte Kalibrierung stehen.
                        // Nur Klasse 3 auszuschließen ließ dichte Bett-Zellen
                        // auf Wald fallen — bei v ≈ 1 immer noch Dämpfung 0.34
                        // statt 0.40, also eine Teil-Panzerung genau in den
                        // flachen Reaches, in denen Bänke entstehen.
                        if prip[k] >= 1 {
                            cls = 1
                        } else if prip[k] >= 0.4 && slope * 40 < 0.6 && phf[k] - ph[k] <= 0.02 && v >= 0.25 {
                            cls = 3
                        } else if v > 0.45 {
                            cls = 2
                        } else {
                            cls = 1
                        }
                    }
                    pcls[k] = cls
                }
            }
            }
        }}}}}
    }

    /// Eine gedämpfte 3×3-Max-Dilatationsrunde: dst[k] = max(src[k],
    /// 0.65·max(8 Nachbarn)). Liest nur src, schreibt nur dst[k] →
    /// zeilenparallel bit-identisch.
    private func dilateDamped(from src: [Double], to dst: inout [Double]) {
        let nn = n
        src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            let ps = sb.baseAddress!, pd = db.baseAddress!
            parallel(nn) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<nn {
                        let k = j * nn + i
                        var m = 0.0
                        if i > 0 && j > 0 { m = max(m, ps[k - nn - 1]) }
                        if j > 0 { m = max(m, ps[k - nn]) }
                        if i < nn - 1 && j > 0 { m = max(m, ps[k - nn + 1]) }
                        if i > 0 { m = max(m, ps[k - 1]) }
                        if i < nn - 1 { m = max(m, ps[k + 1]) }
                        if i > 0 && j < nn - 1 { m = max(m, ps[k + nn - 1]) }
                        if j < nn - 1 { m = max(m, ps[k + nn]) }
                        if i < nn - 1 && j < nn - 1 { m = max(m, ps[k + nn + 1]) }
                        pd[k] = max(ps[k], 0.65 * m)
                    }
                }
            }
        }}
    }

    // MARK: - Priority-Flood + Entwässerung (D8)

    /// Füllt Senken (Barnes et al.), bestimmt Abfluss-Nachbarn (steilster Abstieg
    /// auf der gefüllten Oberfläche) und akkumuliert das Einzugsgebiet.
    ///
    /// `dtYears` steuert NUR die Ratenbegrenzung des Becken-Wasserhaushalts
    /// (Issue #11); 0 = Zielstand sofort übernehmen (Generierung, Breach-Spin-up,
    /// Spieler-Eingriff via `SimNode.recomputeFlow`) — alles andere ist
    /// dt-unabhängig.
    public func computeFlow(includeMFD: Bool = true, dtYears: Double = 0) {
        computeRain()
        floodAndRoute(dt: dtYears)
        if includeMFD { computeMFDArea() }
    }

    /// Senkenfüllung + D8-Routing, dazwischen der Becken-Wasserhaushalt.
    /// Reihenfolge ist bewusst so und nicht anders:
    /// 1. `priorityFlood` liefert den VOLLSTAND (Sill-Niveau) jedes Beckens,
    /// 2. das erste `computeReceiversAndArea` den Abfluss auf diesem Vollstand —
    ///    das ist der ZUFLUSS, den ein Becken maximal bekommen kann (die
    ///    Bilanzgröße; sie ist bewusst unabhängig vom aktuellen Spiegel, sonst
    ///    hinge der Zufluss am eigenen Ergebnis),
    /// 3. `capEndorheicBasins` deckelt `hf` dort, wo die Verdunstung den
    ///    Vollstand nicht tragen kann,
    /// 4. und nur DANN — und nur wenn wirklich gedeckelt wurde — wird das Netz
    ///    auf dem gedeckelten Spiegel neu bestimmt (trockengefallener Boden
    ///    entwässert jetzt in den Restsee, die Seefläche ist terminal).
    /// `applyBalance: false` schaltet den Wasserhaushalt für diesen Aufruf aus
    /// (Becken-Rollen werden gelöscht) — das braucht der Breach-Spin-up, s. dort.
    private func floodAndRoute(dt: Double, applyBalance: Bool = true) {
        priorityFlood()
        // Becken-Rollen VOR der Zufluss-Messung löschen: mit den Rollen des
        // VORIGEN Schritts wären die Seeflächen schon terminal, die Akkumulation
        // käme an der Auslasszelle des Beckens nie an und der gemessene Zufluss
        // hinge an der eigenen Deckelung von gestern (Hysterese, die den Spiegel
        // Schritt für Schritt weiter absenken kann). Pass 1 ist deshalb immer die
        // vollständige, verdunstungs-freie Entwässerung.
        clearEndorheicBasins()
        computeReceiversAndArea()
        guard applyBalance else { return }
        if capEndorheicBasins(dt: dt) { computeReceiversAndArea() }
    }

    /// Becken-Rollen (und damit alle #11-Sonderpfade) zurücksetzen.
    private func clearEndorheicBasins() {
        guard endorheicBasin.contains(where: { $0 != 0 }) else { return }
        for k in 0..<cfg.count { endorheicBasin[k] = 0; playaBed[k] = false; endorheicInflow[k] = 0 }
    }

    /// PERF: der Hot-Loop läuft komplett auf Roh-Puffern (kein Bounds-/COW-Check
    /// je Zugriff), innere Zellen nehmen den Zweig mit 8 FESTEN Offsets ohne
    /// Rand-Checks, und der Spaltenindex reist im Heap-Eintrag mit (kein `c % n`
    /// je Zelle).
    private func priorityFlood() {
        heap.removeAll()
        let cnt = cfg.count, nn = n
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeMutableBufferPointer { hfb in
        visited.withUnsafeMutableBufferPointer { vb in
        floodParent.withUnsafeMutableBufferPointer { pb in
        order.withUnsafeMutableBufferPointer { ob in
        heap.withRaw { heap in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pv = vb.baseAddress!, ppar = pb.baseAddress!, pord = ob.baseAddress!
            pv.update(repeating: false, count: cnt)
            // Ränder als Startpunkte (Meer/Weltrand = Basisniveau). Ohne das
            // Array-Literal je i — das war eine Allokation pro Randzelle.
            @inline(__always) func seed(_ b: Int, _ col: Int32) {
                if pv[b] { return }
                pv[b] = true
                phf[b] = ph[b]
                ppar[b] = -1
                heap.push(key: ph[b], cell: Int32(b), col: col)
            }
            for i in 0..<nn {
                seed(i, Int32(i))                      // Nordrand
                seed((nn - 1) * nn + i, Int32(i))      // Südrand
                seed(i * nn, 0)                        // Westrand
                seed(i * nn + nn - 1, Int32(nn - 1))   // Ostrand
            }
            let lastRow = cnt - nn
            var oi = 0
            while heap.size > 0 {
                let e = heap.pop()
                let c = Int(e.cell), col = Int(e.col)
                pord[oi] = e.cell; oi += 1
                // e.key == hf[c]: die Füllhöhe wird beim Push gesetzt und danach
                // nie mehr geändert → ein Random-Read gespart.
                let hc = e.key
                @inline(__always) func visit(_ nb: Int, _ ncol: Int32) {
                    if pv[nb] { return }
                    pv[nb] = true
                    let v = max(ph[nb], hc)
                    phf[nb] = v
                    ppar[nb] = e.cell
                    heap.push(key: v, cell: Int32(nb), col: ncol)
                }
                if col > 0 && col < nn - 1 && c >= nn && c < lastRow {
                    let cm = e.col
                    visit(c - nn - 1, cm - 1); visit(c - nn, cm); visit(c - nn + 1, cm + 1)
                    visit(c - 1, cm - 1); /* Zentrum */         visit(c + 1, cm + 1)
                    visit(c + nn - 1, cm - 1); visit(c + nn, cm); visit(c + nn + 1, cm + 1)
                } else {
                    let cj = c / nn
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = col + di, nj = cj + dj
                            if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                            visit(nj * nn + ni, Int32(ni))
                        }
                    }
                }
            }
        }}}}}}
    }

    /// Startwert der Flächen-Akkumulation je Zelle — die EINE Stelle für beide
    /// Netze (D8 in `computeReceiversAndArea`, MFD in `computeMFDArea`), damit sie
    /// nicht auseinanderdriften.
    ///
    /// Ohne `cfg.rainWeightedFlow`: reine Zellfläche (`cellArea` überall) —
    /// bit-identisch zum Zustand vor Issue #9. Mit Schalter: `cellArea ·
    /// rainWeight[k]`, d. h. die Akkumulation trägt ABFLUSS statt Fläche
    /// (Q = ∫P dA), auf das Regen-Landmittel normiert (s. `updateRainWeight`) —
    /// Σ über Land bleibt damit exakt `Landzellen · cellArea`.
    /// `rainWeight` ist beim Aufruf frisch (computeFlow ruft computeRain zuerst);
    /// nur der Breach-Spin-up (`breachBasins`) rechnet bewusst auf dem Regen des
    /// letzten `computeFlow` weiter — das Klima ändert sich über eine
    /// Breach-Runde nicht nennenswert.
    /// Per-Zelle unabhängig → parallel bit-identisch zur sequenziellen Schleife.
    private func seedFlowAccumulator(_ pa: UnsafeMutablePointer<Double>, cellArea: Double) {
        let cnt = cfg.count
        guard rainWeight.count == cnt else {
            pa.update(repeating: cellArea, count: cnt)
            return
        }
        rainWeight.withUnsafeBufferPointer { rb in
            let pw = rb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi { pa[k] = cellArea * pw[k] }
            }
        }
    }

    /// PERF wie im Flood: Roh-Puffer, i/j aus der Schleife statt `%`/`/` je Zelle,
    /// innere Zellen mit 8 festen Offsets ohne Rand-Checks. Vergleichsreihenfolge
    /// und `/ dist` bleiben unverändert (strict `>` → der erste steilste gewinnt).
    private func computeReceiversAndArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let sqrt2 = 2.0.squareRoot()
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeMutableBufferPointer { rb in
        area.withUnsafeMutableBufferPointer { ab in
        floodParent.withUnsafeBufferPointer { pb in
        order.withUnsafeBufferPointer { ob in
        endorheicBasin.withUnsafeBufferPointer { eb in
            let phf = hfb.baseAddress!, prec = rb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!, pend = eb.baseAddress!
            prec.update(repeating: -1, count: cnt)
            seedFlowAccumulator(pa, cellArea: cellArea)
            // Empfänger: steilster Abstieg auf hf; auf Seespiegel-Flächen Richtung Überlauf.
            // Jede Zelle schreibt nur prec[k] → zeilenparallel, bit-identisch.
            parallel(nn) { jLo, jHi in
            for j in jLo..<jHi {
                let row = j * nn
                let innerRow = j > 0 && j < nn - 1
                for i in 0..<nn {
                    let k = row + i
                    let hk = phf[k]
                    if hk <= sea { continue } // Meer = Senke
                    var best: Int32 = -1
                    var bestSlope = 0.0
                    @inline(__always) func consider(_ nb: Int, _ dist: Double) {
                        let s = (hk - phf[nb]) / dist
                        if s > bestSlope { bestSlope = s; best = Int32(nb) }
                    }
                    if innerRow && i > 0 && i < nn - 1 {
                        consider(k - nn - 1, sqrt2); consider(k - nn, 1.0); consider(k - nn + 1, sqrt2)
                        consider(k - 1, 1.0); /* Zentrum */              consider(k + 1, 1.0)
                        consider(k + nn - 1, sqrt2); consider(k + nn, 1.0); consider(k + nn + 1, sqrt2)
                    } else {
                        for dj in -1...1 {
                            for di in -1...1 {
                                if di == 0 && dj == 0 { continue }
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                                consider(nj * nn + ni, (di != 0 && dj != 0) ? sqrt2 : 1.0)
                            }
                        }
                    }
                    // Abflussloses Becken (Issue #11): die Wasserfläche ist eine
                    // TERMINALE Senke — das Wasser verlässt sie über die
                    // Verdunstung, nicht über die Sill (deshalb auch dann −1,
                    // wenn die 8er-Nachbarschaft diagonal an einen tieferen
                    // Nachbarsee grenzt). Und im geschlossenen Becken gibt es für
                    // eine flache Bodenzelle keinen Überlauf: der
                    // floodParent-Fallback zeigt zur Sill HINAUS, also genau
                    // dorthin, wo kein Wasser mehr hinkommt.
                    if pend[k] != 0 {
                        if pend[k] == 2 || best < 0 { best = -1 }
                    } else if best < 0 {
                        best = ppar[k] // flacher Seespiegel → Überlauf
                    }
                    prec[k] = best
                }
            }
            }
            // Einzugsgebiet: von hoch nach tief (order rückwärts) an Empfänger weiterreichen.
            var oi = cnt - 1
            while oi >= 0 {
                let k = Int(pord[oi]); oi -= 1
                let r = prec[k]
                if r >= 0 { pa[Int(r)] += pa[k] }
            }
        }}}}}}
    }

    // MARK: - Wasserhaushalt abflussloser Becken (Verdunstung, Issue #11)

    /// Deckelt den Seespiegel eines geschlossenen Beckens auf den Stand, den sein
    /// **Wasserhaushalt** trägt — Zufluss gegen Verdunstung über der Seefläche —
    /// statt ihn (wie der reine Priority-Flood) immer bis zur Sill zu füllen.
    /// Damit gibt es endorheische Becken, Playas und Salzseen; ein Becken mit
    /// genug Zufluss verhält sich exakt wie vorher (Wächter:
    /// `testBasinsDrainToSea`, `testWellFedBasinIsUnchanged`).
    ///
    /// **Bilanz.** Ein Becken ist die Menge zusammenhängender Zellen (8er) mit
    /// `hf > h` und identischem `hf` — der Priority-Flood füllt eine Senke
    /// exakt flach auf ihr Sill-Niveau, deshalb ist die Gleichheit exakt und
    /// nicht approximativ. Für dieses Becken gilt
    ///
    ///     Zufluss A_zu = max(area) über die Beckenzellen
    ///     Bedarf  D(z) = κ · Σ_{h < z} cellArea · aridity(k)
    ///
    /// `A_zu` ist der Abfluss, den das Becken einsammelt: auf dem VOLLSTAND
    /// zeigen alle Beckenzellen über `floodParent` zur Sill, die Akkumulation
    /// läuft also durchs Becken und ist an seiner Auslasszelle maximal. Weil der
    /// Abfluss seit #10 niederschlagsgewichtet und auf das Regen-Landmittel
    /// normiert ist, ist κ das Verhältnis „Seeverdunstung / mittlere
    /// Abflusshöhe" = das nötige Einzugsgebiet-zu-Seefläche-Verhältnis
    /// (Herleitung und Kalibrier-Logbuch: `SimConfig.endorheicEvapRatio`).
    /// Der Regen, der auf den See selbst fällt, steckt schon in `A_zu` — der
    /// Bedarf ist deshalb die BRUTTO-Verdunstung, nicht „Verdunstung − Regen".
    ///
    /// `D(z)` ist eine TREPPENFUNKTION der Seefläche (die Verdunstung hängt an
    /// der Fläche, nicht an der Tiefe) und wächst monoton mit z → der
    /// Gleichgewichtsstand ist der höchste Stand mit `D ≤ A_zu`, und den findet
    /// man exakt, indem man die Beckenzellen nach Höhe sortiert und den Bedarf
    /// aufsummiert. `D(Sill) ≤ A_zu` heißt „Becken trägt den Vollstand" → gar
    /// kein Eingriff (der schnelle Normalfall; nur dann wird sortiert, wenn
    /// wirklich gedeckelt wird).
    ///
    /// **Ratenbegrenzung.** Übernommen wird nicht der Zielstand, sondern ein
    /// exponentieller Schritt dorthin (`endorheicResponseYears`, dt-invariant wie
    /// `relaxWaterLevel`) — ein See füllt und leert sich mit endlicher Rate, und
    /// der Zielstand SPRINGT, wenn Deposition am Auslass die Sill hebt (dann
    /// gehört plötzlich mehr Fläche zum Becken). Gedächtnis ist `lakeBalance` an
    /// der TIEFSTEN Beckenzelle: sie ist die einzige, die in jedem Stand zum
    /// Becken gehört (und bleibt es auch, wenn das Becken vollständig
    /// trockenfällt — der Priority-Flood füllt es im nächsten Schritt wieder,
    /// die Becken-ERKENNUNG hängt also nicht am Wasserstand).
    ///
    /// **Determinismus:** rein sequenziell, Becken-Reihenfolge = aufsteigender
    /// Zellindex, Sortierung nach (h, Index) → bit-identisch reproduzierbar.
    ///
    /// Rückgabe: `true`, wenn mindestens ein Becken verdunstungs-limitiert ist —
    /// dann muss das D8-Netz auf dem gedeckelten Spiegel neu bestimmt werden.
    private func capEndorheicBasins(dt: Double) -> Bool {
        guard cfg.endorheicEvaporation, cfg.endorheicEvapRatio > 0 else {
            if endorheicBasin.contains(where: { $0 != 0 }) {
                for k in 0..<cfg.count { endorheicBasin[k] = 0 }
            }
            return false
        }
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let cellArea = cfg.cellSize * cfg.cellSize
        let kappa = cfg.endorheicEvapRatio
        let aridA = cfg.endorheicAridity
        let weighted = rainWeight.count == cnt
        /// Verdunstungs-Bedarf einer Zelle (Fläche × Klima-Faktor). Ohne
        /// Gewichtsfeld (`rainWeightedFlow` aus) ist er klima-neutral — dann
        /// bilanziert der Pass rein geometrisch.
        @inline(__always) func demand(_ k: Int) -> Double {
            guard weighted, aridA != 0 else { return cellArea * kappa }
            let a = min(4.0, max(0.25, 1 + aridA * (1 - rainWeight[k])))
            return cellArea * kappa * a
        }
        // Ratenbegrenzung; dt = 0 (Generierung/Breach/Spieler-Eingriff) snappt.
        let lam = (dt > 0 && cfg.endorheicResponseYears > 0)
            ? 1 - exp(-dt / cfg.endorheicResponseYears) : 1.0
        for k in 0..<cnt {
            basinSeen[k] = false; endorheicBasin[k] = 0
            playaBed[k] = false; endorheicInflow[k] = 0
        }
        var capped = false
        var orderPosBuilt = false
        for s in 0..<cnt where !basinSeen[s] && hf[s] > sea && hf[s] > h[s] {
            let sill = hf[s] // Priority-Flood füllt die Senke flach auf ihr Sill-Niveau
            basinCells.removeAll(keepingCapacity: true)
            basinCells.append(Int32(s))
            basinSeen[s] = true
            var inflow = 0.0, full = 0.0
            var qi = 0
            while qi < basinCells.count {
                let k = Int(basinCells[qi]); qi += 1
                inflow = max(inflow, area[k])
                full += demand(k)
                let i = k % nn, j = k / nn
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                        let nb = nj * nn + ni
                        if basinSeen[nb] || hf[nb] != sill || hf[nb] <= h[nb] { continue }
                        basinSeen[nb] = true
                        basinCells.append(Int32(nb))
                    }
                }
            }
            // Vollstand getragen (oder Becken unter dem Rausch-Gate) → gar kein
            // Eingriff. Der Bilanz-Stand wird trotzdem mitgeführt, damit ein
            // später kippendes Becken beim Deckeln von der SILL aus absinkt und
            // nicht von einem veralteten Wert (das wäre ein Sprung nach unten).
            if full <= inflow || basinCells.count < cfg.endorheicMinBasinCells {
                for kk in basinCells { lakeBalance[Int(kk)] = sill }
                continue
            }
            // Zielstand: höchster Stand, dessen Seefläche die Verdunstung noch
            // aus dem Zufluss deckt. Sortierung nach (h, Index) ist gleichzeitig
            // die Sortierung nach dem NEUEN hf (= max(h, level), monoton in h) —
            // die braucht das Umsortieren von `order` unten.
            basinCells.sort { (h[Int($0)], $0) < (h[Int($1)], $1) }
            var spent = 0.0, wet = 0
            for kk in basinCells {
                let d = demand(Int(kk))
                if spent + d > inflow { break }
                spent += d; wet += 1
            }
            let target = wet >= basinCells.count ? sill : h[Int(basinCells[wet])]
            let anchor = Int(basinCells[0]) // tiefste Zelle = Gedächtnis des Beckens
            var prev = lakeBalance[anchor]
            if !prev.isFinite { prev = sill }
            prev = min(max(prev, h[anchor]), sill)
            let level = prev + (target - prev) * lam
            for kk in basinCells {
                let k = Int(kk)
                lakeBalance[k] = level
                endorheicInflow[k] = inflow
                if level > h[k] {
                    hf[k] = level
                    endorheicBasin[k] = 2 // Wasserfläche, terminale Senke
                } else {
                    hf[k] = h[k]
                    endorheicBasin[k] = 1 // trockengefallener Beckenboden
                    // Salzpfanne nur, wo auch substanziell Wasser stand.
                    playaBed[k] = sill - h[k] > cfg.endorheicSaltMinDepth
                }
            }
            capped = true
            // `order` (aufsteigende Füllhöhe) muss der gesenkte Spiegel mitziehen:
            // die Akkumulation läuft rückwärts durch `order` und setzt voraus,
            // dass der Empfänger jeder Zelle FRÜHER darin steht. Innerhalb des
            // Beckens stimmt das nach dem Deckeln nicht mehr (alle Zellen lagen
            // auf dem gemeinsamen Sill-Niveau, jetzt liegt der trockene Boden
            // ÜBER dem Restsee). Repariert wird nur lokal: die Plätze des Beckens
            // in `order` bleiben dieselben, die Zellen ziehen darin nach dem
            // neuen hf aufsteigend um. Global bleibt `order` damit nach hf
            // sortiert — außerhalb des Beckens hat sich kein hf geändert, und
            // eine fremde Zelle mit demselben hf kann nie Empfänger einer
            // Beckenzelle sein, die jetzt HÖHER liegt (Empfänger gehen bergab).
            if !orderPosBuilt {
                order.withUnsafeBufferPointer { ob in
                orderPos.withUnsafeMutableBufferPointer { pb in
                    let pord = ob.baseAddress!, ppos = pb.baseAddress!
                    parallel(cnt) { lo, hi in
                        for t in lo..<hi { ppos[Int(pord[t])] = Int32(t) }
                    }
                }}
                orderPosBuilt = true
            }
            basinSlots.removeAll(keepingCapacity: true)
            for kk in basinCells { basinSlots.append(orderPos[Int(kk)]) }
            basinSlots.sort()
            for t in basinSlots.indices {
                let slot = Int(basinSlots[t]), c = basinCells[t]
                order[slot] = c
                orderPos[Int(c)] = Int32(slot)
            }
        }
        return capped
    }

    /// Salzkruste auf trockengefallenem Beckenboden aufbauen bzw. unter Wasser
    /// wieder abbauen (EWMA in Sim-Zeit → dt-invariant, Zeitraffer und
    /// +10.000-Jahre-Sprung landen bei derselben Kruste). Reines Render-/
    /// Vegetations-Signal, keine Erosionsphysik (s. `saltCrust`).
    private func updateSaltCrust(dt: Double) {
        guard cfg.endorheicSaltYears > 0 else { return }
        let lam = 1 - exp(-dt / cfg.endorheicSaltYears)
        saltCrust.withUnsafeMutableBufferPointer { sb in
        playaBed.withUnsafeBufferPointer { pb in
            let ps = sb.baseAddress!, pp = pb.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    let target: Double = pp[k] ? 1 : 0
                    ps[k] += (target - ps[k]) * lam
                }
            }
        }}
    }

    // MARK: - Multi-Flow-Einzugsgebiet (Freeman/Holmgren) — nur Render/Braiding

    /// Verteilt den Abfluss STETIG an ALLE tieferen Nachbarn (Freeman-1991-
    /// Gewichte fᵢ = Sᵢᵖ/ΣSⱼᵖ, p = `cfg.mfdExponent`) statt komplett an den
    /// steilsten wie D8. Ergebnis in `areaMFD`, ausschließlich fürs Rendering und
    /// (später) Braiding — die Erosion nutzt weiter `area` (Single-Flow), damit der
    /// kalibrierte Terrain-Look und die implizite Stabilität unangetastet bleiben.
    ///
    /// Zwei Wirkungen: (1) an einer Mittelbank (lokaler Hoch) bekommen BEIDE
    /// Flanken S>0 → `areaMFD` bleibt links UND rechts hoch → der Lauf teilt sich
    /// und vereint sich unten wieder (mit D8-argmax prinzipiell unmöglich). (2) Die
    /// Gewichte sind stetig in der Topografie → der Lauf gleitet bei kleinen
    /// Änderungen, statt schlagartig auf einen anderen Nachbarn zu kippen (die
    /// gemessene ~27%-Churn je Flow-Update = das „Springen").
    ///
    /// `order` (aufsteigende Füllhöhe) ist auch für MFD ein gültiger topologischer
    /// Order: jeder Ziel-Nachbar liegt tiefer in `hf` → beim Verarbeiten von hoch
    /// nach tief ist `areaMFD[k]` vollständig eingesammelt, bevor es verteilt wird.
    /// Lokale Exponenten-Wahl für die MFD-Verteilung (Quinn 1995: abfluss-
    /// abhängig) — die EINE Stelle für Wasser (computeMFDArea), Sediment
    /// (braidPass) und die Test-Metriken, damit die Fracht exakt dem Wasser
    /// folgt und die Gates nicht auseinanderdriften. Dispersiv (braidDispersion)
    /// nur auf GROSSEN, FLACHEN, SUBAERISCHEN Läufen (= Braid-Plains): Hänge
    /// behalten die Konvergenz (mfdExponent, dendritischer Look), geflutete
    /// Becken-Böden ebenso (Dispersion dort = Sheet-Flow-Konfetti im Render).
    @inline(__always) func mfdLocalExponent(_ k: Int, sMax: Double) -> Double {
        mfdLocalExponent(a: areaMFD[k], sMax: sMax, pond: hf[k] - h[k])
    }
    /// Wert-Variante für die Hot-Loops (die dort auf Roh-Puffern arbeiten und
    /// `self.areaMFD` nicht gleichzeitig lesen dürfen) — EINE Regel, zwei Aufrufer.
    @inline(__always) func mfdLocalExponent(a: Double, sMax: Double, pond: Double) -> Double {
        (a >= mfdMinA && sMax < mfdFlatCell && pond < 0.005)
            ? cfg.braidDispersion : cfg.mfdExponent
    }
    // Schwellen einmal je Terrain (waren `lazy var`: das kostet im 700k-Loop je
    // Zugriff eine Initialisierungs-Prüfung auf einer Klassen-Property).
    private let mfdMinA: Double
    private let mfdFlatCell: Double // Weltslope in Zell-Einheiten

    private func computeMFDArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let sqrt2 = 2.0.squareRoot()
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        areaMFD.withUnsafeMutableBufferPointer { ab in
        floodParent.withUnsafeBufferPointer { pb in
        order.withUnsafeBufferPointer { ob in
        endorheicBasin.withUnsafeBufferPointer { eb in
        // Nachbar-Puffer auf dem Stack (die alten [Int]/[Double] kosteten je
        // Zugriff Bounds- + COW-Prüfung).
        withUnsafeTemporaryAllocation(of: Int32.self, capacity: 8) { nbK in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbW in
            let phf = hfb.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!, pend = eb.baseAddress!
            seedFlowAccumulator(pa, cellArea: cellArea)
            var oi = cnt - 1
            while oi >= 0 {
                let k = Int(pord[oi]); oi -= 1
                let hk = phf[k]
                if hk <= sea { continue } // Meer = Senke, reicht nicht weiter
                // Abflussloses Becken (Issue #11): die Seefläche ist terminal
                // (Verdunstung) — dieselbe Rolle wie das Meer. Das Render-Feld
                // zeigt den Zufluss weiter BIS in den See, nur nicht darüber
                // hinaus. Rollentrennung bleibt: hier wird nichts erodiert.
                if pend[k] == 2 { continue }
                var c = 0
                var sMax = 0.0
                @inline(__always) func consider(_ nb: Int, _ dist: Double) {
                    let s = (hk - phf[nb]) / dist
                    if s > 0 { nbK[c] = Int32(nb); nbW[c] = s; sMax = max(sMax, s); c += 1 }
                }
                let j = k / nn, i = k - j * nn
                if i > 0 && i < nn - 1 && j > 0 && j < nn - 1 {
                    consider(k - nn - 1, sqrt2); consider(k - nn, 1.0); consider(k - nn + 1, sqrt2)
                    consider(k - 1, 1.0); /* Zentrum */              consider(k + 1, 1.0)
                    consider(k + nn - 1, sqrt2); consider(k + nn, 1.0); consider(k + nn + 1, sqrt2)
                } else {
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = i + di, nj = j + dj
                            if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                            consider(nj * nn + ni, (di != 0 && dj != 0) ? sqrt2 : 1.0)
                        }
                    }
                }
                // areaMFD[k] ist beim Verarbeiten schon vollständig akkumuliert
                // (alle Zuflüsse liegen höher in hf) → das Gate im Exponenten-
                // Helfer ist gültig.
                let a = pa[k]
                let p = mfdLocalExponent(a: a, sMax: sMax, pond: hk - ph[k])
                var wsum = 0.0
                for t in 0..<c { nbW[t] = powFast(nbW[t], p); wsum += nbW[t] }
                if c == 0 || wsum <= 0 {
                    // flache Seespiegel-Zelle (kein tieferer Nachbar) → wie D8 über den
                    // Priority-Flood-Überlauf (floodParent) weiterreichen, damit die
                    // Fläche nicht am See versickert. Im abflusslosen Becken NICHT:
                    // der Überlauf zeigt zur Sill hinaus, wo kein Wasser hinkommt.
                    if pend[k] != 0 { continue }
                    let fp = ppar[k]
                    if fp >= 0 { pa[Int(fp)] += a }
                    continue
                }
                for t in 0..<c { pa[Int(nbK[t])] += a * (nbW[t] / wsum) }
            }
        }}}}}}}}
    }

    // MARK: - Braiding (zellulärer Bänke-Bau, Murray & Paola 1994)

    /// Baut Mittelbänke und Fäden auf den großen Läufen — die Verflechtung
    /// (braiding). Minimal-Rezept nach Murray & Paola (Nature 371): (a) Wasser,
    /// das sich lateral aufteilen kann (unser MFD-Feld), plus (b) Bedload-Transport
    /// mit SUPER-LINEARER Kapazität qcᵢ = Kb·(fᵢ·Q·Sᵢ)^m, m≈2.5. Wegen m>1
    /// transportiert der stärkere Faden überproportional viel → er scourt sich ein
    /// und fängt beim nächsten computeFlow noch mehr Wasser (positive Rückkopplung),
    /// während unterversorgte Zellen ihre Fracht ABLAGERN → Bänke wachsen bis knapp
    /// über den Wasserspiegel (braidBarHeight) → der Lauf teilt sich sichtbar und
    /// vereint sich stromab wieder. Fracht wird ∝ Kapazität an die MFD-Empfänger
    /// weitergereicht (Sediment folgt dem starken Faden).
    ///
    /// Reach-gated: nur Zellen mit areaMFD ≥ braidMinCells (substanzielle Flüsse);
    /// Vegetation dämpft den Scour wie überall ((1−0.6·veg), kohäsive Ufer
    /// verflechten real nicht). Kapazität UND Fracht skalieren mit dt → das
    /// Regime ist framerate-/chunking-unabhängig. Massenbilanz: bewegt wird nur,
    /// was der Pass selbst scourt; Deckel wie in transportLimited (nicht unter den
    /// tiefsten Empfänger graben, nicht über Seespiegel+barHeight schütten).
    /// Der explizite laterale Sediment-Term aus M&P entfällt bewusst: die radiale
    /// MFD-Verteilung (bis 8 tiefere Nachbarn) übernimmt die Quer-Streuung —
    /// Bänke entstehen nachweislich (testBraidingBuildsBars).
    private func braidPass(dt: Double) {
        let cellArea = cfg.cellSize * cfg.cellSize
        let minA = cfg.braidMinCells * cellArea
        let mB = cfg.braidExponent
        let kb = cfg.braidCapacity * dt
        let sqrt2 = 2.0.squareRoot()
        for k in 0..<cfg.count { qs[k] = 0 }
        var nbK = [Int](repeating: 0, count: 8)
        var nbW = [Double](repeating: 0, count: 8)
        var nbS = [Double](repeating: 0, count: 8)
        var nbQc = [Double](repeating: 0, count: 8) // wiederverwendet — keine Alloc je Zelle
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(order[oi]); oi -= 1
            let qin = qs[k]
            // Seicht überströmte Reaches (< 0.015) sind aktiv — dort schütten
            // Braid-Deltas Bänke bis über den Wasserspiegel. Tiefere Ponds/Seen
            // NICHT: Bänke-Bau dort macht die Becken-Böden rau um die See-Render-
            // Schwelle (0.03) herum → sichtbares Speckle statt Verflechtung.
            let active = areaMFD[k] >= minA && hf[k] > cfg.sea && h[k] > cfg.sea
                      && hf[k] - h[k] < 0.015
            if !active {
                // Kein Braid-Reach: Fracht landet hier ab (Delta/Seerand), Überschuss
                // über den Stauraum hinaus gilt als exportiert (wie transportLimited).
                if qin > 0 && hf[k] > cfg.sea {
                    depositCell(k, min(qin, max(0, hf[k] - h[k]) + 0.005))
                }
                continue
            }
            // MFD-Empfänger, Gewichte und Gefälle (identisch zu computeMFDArea,
            // inkl. abfluss-abhängigem Exponent — die Fracht folgt dem Wasser).
            let i = k % n, j = k / n
            var cnt = 0
            var sMax = 0.0
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    let dist = (di != 0 && dj != 0) ? sqrt2 : 1.0
                    let s = (hf[k] - hf[nb]) / dist
                    if s > 0 {
                        nbK[cnt] = nb; nbS[cnt] = s; sMax = max(sMax, s)
                        cnt += 1
                    }
                }
            }
            let p = mfdLocalExponent(k, sMax: sMax)
            var wsum = 0.0
            for t in 0..<cnt { nbW[t] = powFast(nbS[t], p); wsum += nbW[t] }
            if cnt == 0 || wsum <= 0 {
                // Seespiegel-Fläche: Fracht sedimentiert im See (bis Spiegel), Rest
                // wandert über den Überlauf weiter.
                let dep = min(qin, max(0, hf[k] - h[k]))
                depositCell(k, dep)
                let fp = floodParent[k]
                if fp >= 0 { qs[Int(fp)] += qin - dep }
                continue
            }
            // Kapazität je Route: qcᵢ = Kb·dt · Q·Sᵢ · fᵢ^m  (Q in Zell-Einheiten).
            // Die Super-Linearität liegt bewusst auf der lateralen PARTITION fᵢ
            // (nicht auf dem absoluten Q, das über das Netz 3 Dekaden spannt): für
            // festes Q trägt EIN Faden (f=1) mehr als zwei halbe (2·0.5^m ≈ 0.35) —
            // die Konzentrations-Instabilität, die Fäden schärft. Und wo der Lauf
            // sich aufspreizt (viele kleine fᵢ → Σfᵢ^m ≪ 1) KOLLABIERT die
            // Kapazität → Deposition genau in den breiten, flachen Reaches → Bänke.
            let q = areaMFD[k] / cellArea
            var qcTot = 0.0
            for t in 0..<cnt {
                nbQc[t] = kb * q * nbS[t] * pow(nbW[t] / wsum, mB)
                qcTot += nbQc[t]
            }
            var qout = qin
            if qin > qcTot {
                // Überlast → Bank bauen: bis knapp über den Wasserspiegel (Insel!).
                let dep = min(qin - qcTot, max(0, hf[k] + cfg.braidBarHeight - h[k]))
                depositCell(k, dep)
                qout -= dep
            } else {
                // Unterlast → Faden scourt (Vegetation bremst, nie unter den
                // tiefsten Empfänger — halber Weg wie transportLimited).
                var lowest = h[k]
                for t in 0..<cnt { lowest = min(lowest, h[nbK[t]]) }
                let want = (qcTot - qin) * vegDamp(k)
                let er = erodeCell(k, min(want, max(0, h[k] - lowest) * 0.5))
                qout += er
            }
            // Fracht folgt der Kapazität (∝ qcᵢ): der starke Faden trägt sie weiter.
            if qout > 0 && qcTot > 1e-30 {
                for t in 0..<cnt { qs[nbK[t]] += qout * (nbQc[t] / qcTot) }
            }
        }
    }

    // MARK: - Transport-limitierte Fluss-Erosion (SPACE-artig) — TESTPFAD

    /// **Nur im Nicht-Droplet-Zweig** (`cfg.hydraulicEnabled = false`), den die
    /// isolierten Mäander-Kopplungstests (`meanderCfg()` in `SimCoreTests.swift`)
    /// bewusst nutzen: Carve/Altarm/Altern ohne Droplet-Rauschen. Produktion
    /// erodiert fluvial über `outletIncision` + `Hydraulic.erode`.
    ///
    /// Massenerhaltender Sedimenttransport: der Fluss trägt eine Fracht `qs` und
    /// gleicht sie an die Transportkapazität Qc = Kt·Aᵐ·S an. Über Kapazität →
    /// Ablagerung (Deltas an Küsten, Schwemmebenen, Beckenfüllung); unter Kapazität
    /// → Erosion (detachment-begrenzt). Löste seinerzeit die reine detachment-
    /// limitierte Grid-Inzision ab (Commit „B (M3)").
    /// Verarbeitung stromauf→stromab (order rückwärts), sodass
    /// die Fracht jeder Zelle bei ihren Zuflüssen schon angekommen ist.
    private func transportLimited(dt: Double) {
        let cs = cfg.cellSize
        let sqrt2 = 2.0.squareRoot()
        let kt = cfg.transportCap
        let m = cfg.mExp
        for k in 0..<cfg.count { qs[k] = 0 }
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(order[oi]); oi -= 1
            let r = receiver[k]
            let qin = qs[k]
            if r < 0 {
                // Meer/Rand: Delta bis Meereshöhe aufbauen, Überschuss geht ins tiefe Meer.
                let room = max(0, cfg.sea - h[k])
                let dep = min(qin, room)
                h[k] += dep; sed[k] += dep
                continue
            }
            let ri = Int(r)
            let ki = k % n, kj = k / n
            let rii = ri % n, rjj = ri / n
            let dist = (ki != rii && kj != rjj) ? cs * sqrt2 : cs
            let a = area[k]
            let s = max(0, (hf[k] - hf[ri]) / dist)
            let qc = kt * pow(a, m) * s
            if qin > qc {
                // über Kapazität → ablagern (aber nicht über den Empfänger hinaus stauen)
                var dep = qin - qc
                let room = max(0, (hf[k] - h[k])) + 0.02 // bis Seespiegel/etwas darüber
                dep = min(dep, room)
                h[k] += dep; sed[k] += dep
                qs[ri] += qin - dep
            } else {
                // unter Kapazität → erodieren (detachment-begrenzt, Fels widerstandsfähiger).
                // Auf Kanalzellen gedämpft: dort inzidiert der Mäander-Carve (Reconciliation).
                let damp = isChannel[k] ? cfg.channelErodeDamp : 1.0
                // Lithologie (Issue #12) skaliert NUR den Fels-Zweig: `kSed` ist
                // lockeres Material und weiß nichts vom Gestein darunter.
                let kBed = lithErodeK.count == cfg.count ? cfg.kRock * lithErodeK[k] : cfg.kRock
                let kErode = (sed[k] > cfg.sedCoverThresh ? cfg.kSed : kBed) * vegDamp(k)
                let want = min(qc - qin, kErode * pow(a, m) * s * dt) * damp
                let removable = max(0, h[k] - h[ri]) * 0.5
                let er = min(want, removable)
                if er > 0 {
                    let ds = min(er, sed[k])
                    sed[k] -= ds
                    rock[k] -= (er - ds)
                    h[k] -= er
                }
                qs[ri] += qin + er
            }
        }
    }

    // MARK: - Auslass-Inzision (Seen entwässern zum Meer)

    /// Tieft die **Auslass-Sille** abflussloser Becken ein, sodass der See zum Meer
    /// entwässert statt vollzulaufen (Droplet-Pfad) oder zur Flach-Ebene zu verlanden
    /// (basinFill). Der Priority-Flood liefert die Zutaten: an einer Sill-Zelle steht
    /// gestautes Wasser an (hf>h in der Nachbarschaft), und ihr `receiver` zeigt über
    /// den Rand aus dem Becken heraus bergab. Stream-Power-Inzision entlang dieser
    /// Zellen senkt die Sill; der nächste computeFlow senkt den Seespiegel (hf) nach —
    /// self-reinforcing, bis das Becken entwässert ist (dann kein Ponding → Stopp).
    /// So entstehen dendritische Grau-Täler statt Kuppeln/Ebenen (nickmcd-Look).
    /// `minAreaCells > 0` beschränkt die Inzision aufs Trunk-Netz (Einzugsgebiet
    /// ≥ so viele Zellen) — für den Generierungs-Breach: Becken-Sillen/Talwege
    /// haben riesige Einzugsgebiete und werden durchschnitten, Hänge und Grate
    /// bleiben unberührt (junges Relief bleibt erhalten).
    /// PERF wie in priorityFlood: der Hot-Loop läuft auf Roh-Puffern (kein
    /// Bounds-/Exclusivity-Check je Zugriff). Sequenziell MUSS er bleiben: der
    /// implizite Solver liest h[Empfänger], der weiter vorn in `order` schon
    /// aktualisiert wurde. pow bleibt pow (s. powFast-Kommentar: 0.5→sqrt wäre
    /// nicht bit-identisch).
    private func outletIncision(dt: Double, minAreaCells: Double = 0) {
        let cs = cfg.cellSize
        let sqrt2 = 2.0.squareRoot()
        let minA = minAreaCells * cs * cs
        let m = cfg.mExp
        let cnt = cfg.count, nn = n, sea = cfg.sea, kOut = cfg.outletErode
        // Lithologie (Issue #12): die fluviale Makro-Rate der Produktion ist DIESE
        // — hier entstehen die lithologischen Knickpunkte. Ohne Feld ein
        // 1-Element-Dummy und Faktor exakt 1.0 → bit-identische Arithmetik.
        let lithOn = lithErodeK.count == cnt
        let lithArr = lithOn ? lithErodeK : [1.0]
        h.withUnsafeMutableBufferPointer { hb in
        lithArr.withUnsafeBufferPointer { lkb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rkb in
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { vcb in
        vegTypeFactor.withUnsafeBufferPointer { tfb in
        area.withUnsafeBufferPointer { ab in
        order.withUnsafeBufferPointer { ob in
        receiver.withUnsafeBufferPointer { rb in
        endorheicBasin.withUnsafeBufferPointer { eb in
            let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rkb.baseAddress!
            let pveg = vb.baseAddress!, pa = ab.baseAddress!
            let pcls = vcb.baseAddress!, ptf = tfb.baseAddress!
            let pord = ob.baseAddress!, prec = rb.baseAddress!, pend = eb.baseAddress!
            let plith = lkb.baseAddress!
        // Stromabwärts→aufwärts (order = aufsteigende Füllhöhe): der Empfänger ist
        // schon aktualisiert, die Inzision propagiert sill-erhaltend flussaufwärts.
        for oi in 0..<cnt {
            let k = Int(pord[oi])
            let r = prec[k]
            if ph[k] <= sea { continue }            // Meer nicht einschneiden
            if pa[k] < minA { continue }            // Breach: nur das Trunk-Netz
            // Abflussloses Becken (Issue #11): die Seefläche hat keinen Auslass,
            // also gibt es dort nichts einzuschneiden. Die SILL bleibt dabei
            // ganz ohne Sonderfall stehen — sie sammelt den Beckenabfluss nicht
            // mehr ein (terminale Senke), ihr A^m ist winzig, die Inzision
            // versandet von selbst. Genau so hört ein endorheisches Becken auf,
            // sich selbst zu entwässern.
            if pend[k] == 2 { continue }
            let hr: Double
            let dist: Double
            if r < 0 {
                // Trockengefallener Beckenboden ohne Empfänger (flache Zelle im
                // geschlossenen Becken): das virtuelle Basisniveau MEER unten
                // gilt nur am Weltrand — im Becken würde es den Boden Richtung
                // Meeresspiegel ausgraben.
                if pend[k] != 0 { continue }
                // Land-Zelle ohne Empfänger = Weltrand (Priority-Flood-Seed):
                // Wasser verlässt hier die Welt → virtuelles Basisniveau MEER.
                // Ohne das wirkt der Rand als unerodierbarer Pegel und Becken,
                // die über den Rand entwässern, können nie tiefer ausschneiden
                // (gemessen: See blieb 28 Breach-Runden bei exakt 2656 Zellen).
                hr = sea
                dist = cs
            } else {
                let ri = Int(r)
                if ph[k] <= ph[ri] { continue }     // See/Ebene: kein Gefälle → keine Inzision
                let i = k % nn, j = k / nn
                let rii = ri % nn, rjj = ri / nn
                hr = ph[ri]
                dist = (i != rii && j != rjj) ? cs * sqrt2 : cs
            }
            // Reine Flächen-Stream-Power: die Inzision konzentriert sich auf Zellen mit
            // großem Einzugsgebiet (Täler/Auslässe) und lässt Grate in Ruhe → dendritisch
            // statt verrauscht. Ein Becken-Auslass sammelt das ganze Becken → tieft zügig
            // ein → See entwässert zum Meer.
            // Vegetation bremst — klassen-gewichtet wie vegDamp (Roh-Puffer-Variante).
            let kErode = kOut * max(0, 1 - 0.6 * ptf[Int(pcls[k])] * pveg[k])
                              * (lithOn ? plith[k] : 1.0)
            let f = kErode * dt * pow(pa[k], m) / dist
            let hNew = (ph[k] + f * hr) / (1 + f)
            var delta = ph[k] - hNew                // > 0
            if delta <= 0 { continue }
            let ds = min(delta, psed[k])            // erst Sediment, dann Fels
            psed[k] -= ds; delta -= ds
            prock[k] -= delta
            ph[k] = hNew
        }
        }}}}}}}}}}}
    }

    // MARK: - Seen-Verfüllung

    /// Füllt Senken (hf > h) langsam mit Sediment auf — Näherung an den
    /// Sediment-Transport (den detachment-limited Stream-Power nicht leistet):
    /// große geschlossene Becken werden über die Zeit zu flachen Schwemmebenen
    /// statt riesiger Seen. Volle SPACE-Physik (Deltas/Mäander) folgt in M3.
    private func fillLakes(dt: Double) {
        let rate = min(0.5, dt / 3000.0) // Zeitkonstante ~3000 Jahre
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            let deficit = hf[k] - h[k]
            if deficit > 0.001 {
                let add = deficit * rate
                h[k] += add
                sed[k] += add
            }
        }
    }

    /// Pfützen-Verlandung: SEICHTES Ponding (≤ puddleFillDepth) auf Land füllt
    /// sich mit Sediment auf — die Auen trugen sonst dauerhafte Flachwasser-
    /// Sprenkel knapp über der Render-Schwelle (zerfetzte Blob-Felder). Anders
    /// als `fillLakes` tiefen-GEDECKELT: echte Seen (tieferes Becken) bleiben.
    /// Mäander-Betten (isChannel) sind ausgenommen (Reconciliation: das
    /// gecarvte Bett nicht zuschütten).
    ///
    /// NUR Komponenten OHNE SEE-KERN (4er-BFS über zusammenhängendes Ponding):
    /// die Pauschal-Verfüllung hob sonst auch die kilometerbreiten Sub-0.06-
    /// Ufersäume der großen Seen als Ganzes an — sichtbar „wachsender Boden
    /// ohne Wasser" (User-Beobachtung; gemessen: 90% der Tiefland-Hebung,
    /// +0.03/6000 J. auf den Säumen). Ein SEE ist eine Komponente mit tiefem
    /// Kern (max-Tiefe > puddleFillDepth — dieselbe „echte Seen bleiben"-
    /// Semantik wie der Tiefen-Deckel); sein Ufersaum verlandet nur noch
    /// physisch über die Droplet-Deltas (Sediment-ZUFUHR von den Mündungen,
    /// gerichtet). Braid-/Auen-Pfützennetze sind überall seicht → verlanden
    /// weiter komplett, egal wie ausgedehnt (eine Größen-Schwelle traf je nach
    /// Seed auch Bank-Pfützen: Braid-Insel-Guard kippte bei 64 UND 400 Zellen).
    /// Ziel bewusst das volle hf, NICHT der geglättete waterLevel (über 3 Seeds
    /// ohne messbaren Volumen-Effekt, drückte aber die Braid-Bänke 9→2).
    private func fillShallowPonds(dt: Double) {
        let rate = min(0.5, dt / cfg.puddleFillYears)
        let sea = cfg.sea, nn = n
        // Persistente Puffer (Hot-Loop, keine Allokation je Schritt).
        for k in 0..<cfg.count { pondSeen[k] = false }
        var comp: [Int32] = []
        var stack: [Int32] = []
        for s in 0..<cfg.count where !pondSeen[s] && hf[s] > sea && hf[s] - h[s] > 0.001
                                     && endorheicBasin[s] != 2 {
            comp.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(s)); pondSeen[s] = true
            var deepCells = 0
            while let kk = stack.popLast() {
                let k = Int(kk)
                comp.append(kk)
                if hf[k] - h[k] > cfg.puddleFillDepth { deepCells += 1 }
                let i = k % nn, j = k / nn
                if i > 0 { pondPush(k - 1, &stack) }
                if i < nn - 1 { pondPush(k + 1, &stack) }
                if j > 0 { pondPush(k - nn, &stack) }
                if j < nn - 1 { pondPush(k + nn, &stack) }
            }
            // See = Komponente mit SUBSTANZIELLEM tiefen Kern (absolute Zellzahl):
            // deren Ufersaum bleibt. Zwei verworfene Kriterien (beide gemessen):
            // „berührt irgendeinen tiefen Pool" nahm auch Braid-/Auen-Netze aus,
            // die fast immer an einem Einzelpool hängen (Braid-Insel-Guard kippte
            // 3 vs 4); ein RELATIVER Kern-Anteil (≥20%) ließ genau den Problemfall
            // durch — riesiger seichter Saum um kompakten tiefen Kern (Seed 1337:
            // nur −45% Saum-Hebung statt −100%).
            if deepCells >= cfg.puddleLakeCoreCells { continue }
            for kk in comp {
                let k = Int(kk)
                if isChannel[k] { continue }
                // Frische Baustelle (Issue #26): auf gestörten Zellen NICHT
                // verlanden. Die Pfützen-Verlandung ist ein Aufräum-Pass gegen
                // Flachwasser-Sprenkel in reifen Auen — auf einer eben erst
                // planierten Fläche würde sie genau das Mikro-Relief wieder
                // zuschütten, aus dem sich die neue Entwässerung organisiert
                // (junge Grundmoränen-Landschaften sind Seen-Mosaike, keine
                // trockenen Platten). Schwelle 5 % Reststörung ≈ 3 τ: danach ist
                // die Fläche wieder ein normaler Auen-Standort.
                if disturbActive && disturb[k] > 0.05 { continue }
                let deficit = hf[k] - h[k]
                if deficit > 0.001 && deficit <= cfg.puddleFillDepth {
                    let add = deficit * rate
                    h[k] += add
                    sed[k] += add
                }
            }
        }
    }

    /// BFS-Schritt der Pfützen-Komponentensuche (4er-Nachbarschaft).
    /// Die Wasserfläche eines abflusslosen Beckens (Issue #11) ist hier bewusst
    /// KEINE Pfütze: ihren Spiegel setzt der Wasserhaushalt, und eine
    /// verdunstungs-gedeckelte Playa ist per Konstruktion seicht — die
    /// Pfützen-Verlandung würde also genau die Fläche zuschütten, die #11 gerade
    /// freigelegt hat (und der Beckenboden trocknet ohnehin aus, statt zu
    /// verlanden). Der trockengefallene Boden hat hf = h und fällt schon durchs
    /// Tiefen-Gate.
    @inline(__always) private func pondPush(_ k: Int, _ stack: inout [Int32]) {
        if !pondSeen[k] && hf[k] > cfg.sea && hf[k] - h[k] > 0.001
            && endorheicBasin[k] != 2 {
            pondSeen[k] = true
            stack.append(Int32(k))
        }
    }

    // MARK: - Auen-Aggradation (Overbank-Deposition → flache Schwemmebenen)

    /// Baut flache Auenböden entlang der Flüsse: für jede Fluss-Zelle (großes
    /// Einzugsgebiet) werden die tal-nahen *tieferen* Zellen mit Sediment bis knapp
    /// über das Bett-Niveau (bankfull) aufgefüllt. Ergebnis: breite Niedrig-Gradient-
    /// Reaches, in denen ein Fluss lateral wandern kann (mäandern/verflechten) —
    /// ohne sie sind die gecarvten V-Täler zu schmal dafür (gemessen: nur ~1500
    /// Zellen größte zusammenhängende Aue).
    ///
    /// NUR tal-nahe Zellen UNTER `bett+Auenhöhe` werden gefüllt → steile Talwände
    /// und Berge (darüber) bleiben unberührt. Deposition-only und auf die Auenhöhe
    /// gedeckelt → konvergiert. Größere Flüsse → höhere & breitere Auen (∝ log
    /// Abfluss). Physisch = Overbank-/Schwemm-Deposition.
    ///
    /// STABILITÄT (wichtig): die **Kanalzellen sind die Referenz und werden NIE
    /// angehoben** — nur *Nicht*-Kanal-Zellen werden aggradiert. Sonst pumpen sich
    /// auf flachen Reaches benachbarte Kanalzellen (Slope < depth) gegenseitig hoch
    /// (A hebt B→A+depth, B hebt A→B+depth) → Runaway (gemessen: maxH 0.95→10.7).
    /// Da Nicht-Kanal-Zellen ihrerseits nichts anheben, gibt es keine Rückkopplung:
    /// jede Aue-Zelle konvergiert gegen max(Kanalbett+Auenhöhe) in ihrer Nähe.
    private func floodplainAggradation(dt: Double) {
        let cellArea = cfg.cellSize * cfg.cellSize
        let minA = cfg.floodplainMinArea
        let rate = min(0.6, dt / cfg.floodplainFillYears)
        if rate <= 0 { return }
        for k in 0..<cfg.count {
            if hf[k] <= cfg.sea || h[k] <= cfg.sea { continue }
            if h[k] > cfg.floodplainMaxElev { continue }      // nur Tiefland-Reaches (Auen sind Tiefland)
            let cu = area[k] / cellArea
            if cu < minA { continue }                         // nur Hauptflüsse bauen Auen
            let mag = log(cu / minA + 1)
            let level = h[k] + cfg.floodplainDepth + cfg.floodplainDepthK * mag // bankfull-Referenz
            let w = min(9, max(1, Int((cfg.floodplainWidthK * mag).rounded())))
            let i = k % n, j = k / n
            let jLo = max(0, j - w), jHi = min(n - 1, j + w)
            let iLo = max(0, i - w), iHi = min(n - 1, i + w)
            for nj in jLo...jHi {
                for ni in iLo...iHi {
                    let nb = nj * n + ni
                    if nb == k { continue }
                    if area[nb] / cellArea >= minA { continue } // andere Kanalzelle = Referenz, NIE anheben
                    if h[nb] <= cfg.sea { continue }            // Meer nicht auffüllen
                    if h[nb] >= level { continue }              // Talwand/über Aue → unberührt
                    let add = (level - h[nb]) * rate
                    sed[nb] += add; h[nb] += add                // Aggradation (Sediment)
                }
            }
        }
    }

    // MARK: - Hangdiffusion (linear, uniformes kappa) — TESTPFAD

    /// **Nur im Nicht-Droplet-Zweig** (`cfg.hydraulicEnabled = false`) — dort
    /// zusammen mit `transportLimited` der Grid-Pfad der isolierten Mäander-
    /// Kopplungstests. Der Produktionspfad diffundiert über
    /// `hillslopeDiffusion` (räumlich variables kappa, dt-invariant sub-getaktet).
    ///
    /// Lineare Diffusion dh/dt = D·∇²h — glatte, natürliche Hänge (konkav/konvex)
    /// statt der planaren Facetten/Terrassen der Schwellen-Talus-Methode.
    /// kappa uniform und fix (≪ 0.25 → explizit stabil), `passes`-mal pro Sim-Schritt.
    private func diffusionPass(kappa: Double = 0.0025) {
        if kappa <= 0 { return }
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let hl = i > 0 ? h[k - 1] : h[k]
                let hr = i < n - 1 ? h[k + 1] : h[k]
                let hd = j > 0 ? h[k - n] : h[k]
                let hu = j < n - 1 ? h[k + n] : h[k]
                scratch[k] = kappa * (hl + hr + hd + hu - 4 * h[k])
            }
        }
        for k in 0..<cfg.count {
            let dh = scratch[k]
            if dh == 0 { continue }
            if dh >= 0 {
                sed[k] += dh
            } else {
                let ds = min(-dh, sed[k])
                sed[k] -= ds
                rock[k] -= (-dh - ds)
            }
            h[k] += dh
        }
    }

    /// Hangdiffusion mit RÄUMLICH VARIABLEM kappa. Bodenkriechen braucht Boden:
    /// soil-mantled/sanfte/bewachsene Hänge runden voll aus, aber **hoher, steiler,
    /// kahler Fels kriecht kaum** → dort bleiben spitze Gipfel/Grate stehen (die
    /// Ausnahme, nicht die Regel). So altert die Landschaft ungleichmäßig-natürlich
    /// statt uniform-rund. `base` = kappa auf voll diffundierenden Zellen.
    /// PERF: beide Pässe sind per-Zelle unabhängig (Pass 1 liest h/sed/veg,
    /// schreibt nur scratch[k]; Pass 2 liest scratch, schreibt nur h/sed/rock[k])
    /// → datenparallel auf Roh-Puffern, bit-identisch zur sequenziellen Schleife.
    private func hillslopeDiffusion(base: Double) {
        if base <= 0 { return }
        let nn = n, cnt = cfg.count
        // Lithologie (Issue #12): harte Bänke kriechen langsamer. OHNE das gibt es
        // keinen dauerhaften Hangknick — die Diffusion rundet die Kante der harten
        // Bank weg, egal wie langsam der Fluss sie einschneidet (Wächter:
        // `Lithology.testDiffusionContrastEffectIsMeasured`). Faktor exakt 1.0, wenn
        // das Feld fehlt oder der Kontrast 0 ist → bit-identische Arithmetik.
        let lithDC = lithHardness.count == cnt ? cfg.lithDiffusionContrast : 0
        let lithArr = lithDC != 0 ? lithHardness : [0.0]
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rkb in
        veg.withUnsafeBufferPointer { vb in
        lithArr.withUnsafeBufferPointer { ldb in
        scratch.withUnsafeMutableBufferPointer { scb in
            let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rkb.baseAddress!
            let pveg = vb.baseAddress!, psc = scb.baseAddress!
            let phard = ldb.baseAddress!
            parallel(nn) { jLo, jHi in
            for j in jLo..<jHi {
                for i in 0..<nn {
                    let k = j * nn + i
                    let hl = i > 0 ? ph[k - 1] : ph[k]
                    let hr = i < nn - 1 ? ph[k + 1] : ph[k]
                    let hd = j > 0 ? ph[k - nn] : ph[k]
                    let hu = j < nn - 1 ? ph[k + nn] : ph[k]
                    let lap = hl + hr + hd + hu - 4 * ph[k]
                    // Kahler-Fels-Faktor: hoch (h>0.5), steil und unbewachsen → wenig
                    // Kriechen. Sediment/Vegetation heben das Kriechen wieder an.
                    let gx = (hr - hl) * 0.5, gy = (hu - hd) * 0.5
                    let slope = (gx * gx + gy * gy).squareRoot()
                    let steep = min(1, slope * 26)               // etwas früher „steil" → mehr Grate bleiben scharf
                    let high = min(1, max(0, (ph[k] - 0.42) / 0.35)) // Schutz schon ab mittlerer Höhe
                    let soil = min(1, psed[k] / 0.02 + pveg[k])  // Boden ODER Bewuchs → Kriechen
                    let bare = steep * high * max(0, 1 - soil)   // 1 = kahler steiler Hochfels
                    var localK = base * (1 - 0.92 * bare)        // dort bis auf 8% gedrosselt (Gipfel bleiben spitz)
                    // Gesteinshärte: D = 1 − c·hard, Untergrenze 0.05 (kein
                    // vollständig eingefrorener Hang, auch bei c > 1).
                    if lithDC != 0 { localK *= max(0.05, 1 - lithDC * phard[k]) }
                    psc[k] = localK * lap
                }
            }
            }
            parallel(cnt) { lo, hi in
            for k in lo..<hi {
                let dh = psc[k]
                if dh == 0 { continue }
                if dh >= 0 {
                    psed[k] += dh
                } else {
                    let ds = min(-dh, psed[k])
                    psed[k] -= ds
                    prock[k] -= (-dh - ds)
                }
                ph[k] += dh
            }
            }
        }}}}}}
    }

    // MARK: - Wellenerosion (Küstenzone)

    private func wavePass() {
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let k = idx(i, j)
                if abs(h[k] - cfg.sea) > cfg.waveBand { continue }
                var best = -1
                var bestDrop = cfg.waveTalus
                for nb in [k - 1, k + 1, k - n, k + n] {
                    let d = h[k] - h[nb]
                    if d > bestDrop { bestDrop = d; best = nb }
                }
                if best >= 0 {
                    let move = (bestDrop - cfg.waveTalus) * 0.5 * cfg.waveRelax
                    let ms = min(move, sed[k])
                    let mr = (move - ms) * 0.5
                    sed[k] -= ms
                    rock[k] -= mr
                    h[k] -= ms + mr
                    sed[best] += ms + mr
                    h[best] += ms + mr
                }
            }
        }
    }

    // MARK: - Tektonik / Isostasie

    /// `gatedAmount` ist die bereits über den Schritt INTEGRIERTE Hebung (Höhen-
    /// einheiten bei `upliftBase == 1`) der abklingenden Tektonik bzw. des
    /// Servo-Bodens; `cfg.upliftPer100y` ist die Alt-Konstante (Produktion 0, nur
    /// noch von Testkonfigs gesetzt) und wirkt weiter über das VOLLE Feld.
    private func applyUplift(dt: Double, gatedAmount us: Double = 0) {
        let uf = cfg.upliftPer100y * dt / 100
        // Die abklingende Hebung wirkt NUR über den POSITIVEN Teil des Tektonik-
        // Felds und NUR auf LAND: sie soll Grate tragen. Mit vollem upliftBase
        // (Täler negativ) SENKTE sie die Täler unter den Meeresspiegel (halbe
        // Insel geflutet); ohne Land-Gate hob sie den SCHELF in Tektonik-Ringen
        // über die Wasserlinie (grüne Kratersäume vor der Küste — beides gemessen).
        if uf == 0 && us <= 0 { return }
        for k in 0..<cfg.count {
            let gated = (us > 0 && h[k] > cfg.sea) ? max(0, upliftBase[k]) * us : 0
            let du0 = upliftBase[k] * uf + gated
            var du: Double
            if du0 > 0 {
                du = du0 * max(0, 1 - h[k] / cfg.isoHighClamp)
            } else {
                du = du0 * min(1, (h[k] - cfg.floor) / cfg.isoLowRange)
            }
            if h[k] + du < cfg.floor { du = cfg.floor - h[k] }
            rock[k] += du
            h[k] += du
        }
    }

    // MARK: - Sculpting (Spieler-Eingriff)

    /// Hebt (`dir` > 0) bzw. senkt (`dir` < 0) das Terrain in einem weichen Pinsel
    /// um das Gitterzentrum (`gx`, `gz`), Radius in Welteinheiten. Koppelt in die
    /// Tektonik (angehobene Zonen werden Hebungszonen), damit Eingriffe langfristig
    /// erhalten bleiben statt von der Erosion ausradiert zu werden.
    public func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double,
                       strength: Double = 1.0) {
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            applyDelta(k, dir * 0.006 * strength * w, asRock: true)
            // Kopplung in die Tektonik: angehobene Zonen werden Hebungszonen,
            // damit Eingriffe langfristig erhalten bleiben statt wegzuerodieren.
            upliftBase[k] = min(max(upliftBase[k] + dir * 0.006 * strength * w * 1.5, -2), 2)
        }
    }

    /// Glättet das Terrain im Pinsel Richtung 3×3-Mittel (aus einem Schnappschuss,
    /// damit die Zellreihenfolge das Ergebnis nicht verfälscht).
    public func smooth(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        let snap = h
        let pull = min(1, 0.30 * strength)
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            let i = k % n, j = k / n
            var s = 0.0, c = 0.0
            for dj in max(0, j - 1)...min(n - 1, j + 1) {
                for di in max(0, i - 1)...min(n - 1, i + 1) {
                    s += snap[dj * n + di]; c += 1
                }
            }
            applyDelta(k, (s / c - snap[k]) * pull * w, asRock: false)
        }
    }

    /// Zieht das Terrain im Pinsel Richtung Zielhöhe (Plateau/Terrasse) —
    /// die Zielhöhe sampelt der Aufrufer beim Strich-Beginn.
    public func flatten(gx: Double, gz: Double, radiusWorld: Double,
                        targetHeight: Double, strength: Double = 1.0) {
        let target = min(max(targetHeight, cfg.floor), 1.4)
        let pull = min(1, 0.18 * strength)
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            applyDelta(k, (target - h[k]) * pull * w, asRock: false)
        }
    }

    /// Prägt fraktales Rauschen ins Terrain (zerklüftete Details). Nutzt das
    /// terrain-eigene Noise-Feld → wiederholte Striche vertiefen dasselbe Muster.
    public func roughen(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            let i = k % n, j = k / n
            let nz = noise.fbm01(Double(i) * 0.11, Double(j) * 0.11, octaves: 4) * 2 - 1
            applyDelta(k, nz * 0.005 * strength * w, asRock: true)
        }
    }

    /// Spitzhacke: schmaler, spitzer Hieb, der schnell durch Sediment UND Fels
    /// schlägt — so lassen sich Flüsse gezielt umleiten (Durchbruchstal).
    /// BEWUSST ohne Tektonik-Kopplung (anders als sculpt): nach dem Hieb übernimmt
    /// die Natur — ein gekaperter Fluss hält sich die Rinne per Erosion selbst
    /// offen, und übertiefte Löcher füllen sich über die Zeit mit Sediment.
    /// Der Radius ist auf wenige Zellen GEDECKELT, unabhängig vom Pinsel-Slider:
    /// mit dessen Standardbreite (~64 Zellen) riss der „spitze Hieb" in unter
    /// einer Sekunde einen Krater bis unters Meer, statt eine Kerbe zu schlagen.
    public func pickaxe(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        let radius = min(radiusWorld, Terrain.pickaxeMaxCells * cfg.cellSize)
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radius) { k, w in
            let spike = w * w // (1-d²)⁴ — deutlich spitzer als der weiche Pinsel
            applyDelta(k, -0.02 * strength * spike, asRock: true)
        }
    }

    /// Maximale Spitzhacken-Breite in Zellen (auch fürs Ring-Visual im Frontend).
    public static let pickaxeMaxCells = 3.0

    /// Gemeinsame Pinsel-Iteration: ruft `body(k, w)` für jede Zelle im Pinsel
    /// mit weichem Abfall-Gewicht w ∈ (0..1] auf.
    private func forEachBrushCell(gx: Double, gz: Double, radiusWorld: Double,
                                  _ body: (Int, Double) -> Void) {
        let rCells = radiusWorld / cfg.cellSize
        if rCells <= 0 { return }
        let r = Int(rCells.rounded(.up))
        let cx = Int(gx.rounded()), cz = Int(gz.rounded())
        let jLo = max(0, cz - r), jHi = min(n - 1, cz + r)
        let iLo = max(0, cx - r), iHi = min(n - 1, cx + r)
        if jLo > jHi || iLo > iHi { return }
        for j in jLo...jHi {
            for i in iLo...iHi {
                let d = (Double(i) - gx).magnitudeHypot(Double(j) - gz) / rCells
                if d > 1 { continue }
                body(idx(i, j), (1 - d * d) * (1 - d * d))
            }
        }
    }

    /// Höhenänderung mit Fels/Sediment-Buchhaltung (hält h = rock + sed):
    /// Absenken räumt erst Sediment, dann Fels; Anheben schiebt Fels hoch
    /// (`asRock`) oder lagert lockeres Sediment ab (Glätten/Einebnen).
    private func applyDelta(_ k: Int, _ dhRaw: Double, asRock: Bool) {
        let dh = min(max(h[k] + dhRaw, cfg.floor), 1.4) - h[k]
        if dh >= 0 {
            if asRock { rock[k] += dh } else { sed[k] += dh }
        } else {
            let ds = min(-dh, sed[k])
            sed[k] -= ds
            rock[k] -= (-dh - ds)
        }
        h[k] += dh
        // Lockeres Material setzt sich, Fels nicht (s. registerDisturbance).
        registerDisturbance(k, dh, settles: !asRock)
    }

    // MARK: - Störung & Regeneration (Issue #26)

    /// Bucht die Höhenänderung `dh` (mit Vorzeichen) als **Störung** der Zelle
    /// `k`: nimmt ihr sofort den Zustand, der an der ALTEN Topografie hing, und
    /// legt das Regenerations-Budget an, das die kommenden Jahrhunderte
    /// eintragen.
    ///
    /// Warum hier und nicht je Werkzeug: `applyDelta` ist der gemeinsame
    /// Trichter aller Pinsel (Anheben, Absenken, Glätten, Einebnen, Aufrauen,
    /// Spitzhacke) — die Doktrin „ein Geländeeingriff stört den gekoppelten
    /// Zustand" gilt für jeden davon, nicht nur fürs Einebnen.
    ///
    /// Zurückgesetzt wird ANTEILIG (`raw`), nicht hart: ein zaghafter Strich
    /// lichtet den Wald, ein Bagger-Zug räumt ihn ab. `vegClass` und die
    /// Baum-Instanzen im Frontend leiten sich aus `veg` ab und folgen von
    /// selbst; Mäanderlinien/Altarme hängen an Geometrie und werden erst im
    /// Schritt darauf gesäubert (`regenerateDisturbed`), weil das ein Sweep
    /// über die Linien ist und kein Per-Zell-Effekt.
    ///
    /// Das Budget hat zwei Anteile:
    /// * **Setzung/Rebound** `−dh·disturbanceSettle`: ein Teil des bewegten
    ///   Materials kommt zurück. Frische Auffüllung setzt sich (differentielle
    ///   Kompaktion — über begrabenen Hochlagen weniger als über begrabenen
    ///   Tälern, weshalb die alte Struktur gedämpft wieder durchschlägt),
    ///   entlastetes Gelände hebt sich. Genau dieser Anteil bringt die
    ///   Entwässerung wieder in Gang: die begrabenen Täler werden wieder zu
    ///   Tiefenlinien, statt dass die Fläche auf einen Zufallsgradienten warten
    ///   muss. Er ist STRUKTURTREU (folgt der Eingriffs-Geometrie), nicht
    ///   global — das Werkzeug bleibt wirksam, es bleibt nur nicht steril.
    /// * **Mikro-Relief** `raw·disturbanceReliefAmp·fBm`: der Symmetriebruch
    ///   für Flächen, die schon vorher eben waren (dort ist die Setzung
    ///   uniform und erzeugt kein Gefälle).
    ///
    /// Beide Anteile landen im gleichen Budget und werden über das Abklingfenster
    /// verteilt — der SOFORTeffekt des Werkzeugs bleibt exakt so, wie der Spieler
    /// ihn gezogen hat (Wächter `testFlattenIsExactlyFlatImmediately`).
    @inline(__always) private func registerDisturbance(_ k: Int, _ dh: Double, settles: Bool) {
        guard cfg.disturbanceEnabled, cfg.disturbanceFullChange > 0, dh != 0 else { return }
        let raw = min(1, abs(dh) / cfg.disturbanceFullChange)
        // Nur der Zuwachs, der den Störungsgrad WIRKLICH hebt, darf Mikro-Relief
        // nachlegen — sonst summierten 200 Striche auf derselben Zelle das
        // 200-fache Rauschen auf.
        let old = disturb[k]
        let effInc = min(1, old + raw) - old
        disturb[k] = old + effInc
        disturbActive = true
        if settles { regenPending[k] -= dh * cfg.disturbanceSettle }
        if effInc > 0 && cfg.disturbanceReliefAmp > 0 {
            let i = k % n, j = k / n
            let f = cfg.disturbanceReliefFreq
            // Ortsfestes fBm (terrain-eigener Seed → deterministisch und über
            // wiederholte Eingriffe kohärent: derselbe Fleck bekommt dieselbe
            // Rille, statt bei jedem Strich neu zu würfeln). Versatz 137/91
            // gegen das Aufrau-Werkzeug, damit beide nicht dasselbe Muster prägen.
            let u = noise.fbm01(Double(i) * f + 137, Double(j) * f + 91, octaves: 5) * 2 - 1
            regenPending[k] += effInc * cfg.disturbanceReliefAmp * u
        }
        // Übrig bleibt vom alten Zustand exakt der Anteil `1 − Störungsgrad`
        // (die Quotienten-Form teleskopiert über beliebig viele Striche: ein
        // zaghafter Strich lichtet den Wald, ein Bagger-Zug räumt ihn ab).
        let keep = disturb[k] >= 1 ? 0 : (1 - disturb[k]) / (1 - old)
        veg[k] *= keep          // frisch bewegter Boden trägt keinen alten Bestand
        streamRate[k] *= keep   // …und kein Gedächtnis an den alten Lauf
        streamMap[k] *= keep
    }

    /// Regenerations-Pass für gestörte Zellen — der Kern von Issue #26.
    ///
    /// Drei Wirkungen, alle **räumlich** auf `disturb > 0` und **zeitlich** auf
    /// das Abklingfenster `disturbanceRecoveryYears` begrenzt:
    ///
    /// 1. **Gelände**: je Schritt wird der Anteil `1 − e^(−dt/τ)` des offenen
    ///    Budgets (`regenPending`: Setzung/Rebound + Mikro-Relief) eingetragen
    ///    und abgezogen. Damit teleskopiert die Summe über beliebig viele
    ///    Teilschritte exakt zum Ergebnis EINES Sprungs (Framerate-Invariante,
    ///    Wächter `testRegenerationIsFramerateIndependent`), und die exakt
    ///    flache Platte bekommt den Gradienten, den `outletIncision`
    ///    (überspringt gefällelose Zellen) und die Tropfen (enden bei
    ///    verschwindendem Gradienten) zum Arbeiten brauchen.
    /// 2. **Mäander-/Altarm-Zustand** stark gestörter Zellen fällt weg; die
    ///    Läufe werden aus der frischen Entwässerung neu getrasst.
    /// 3. **Vegetation**: das Ziel wird in `updateVegetation` mit
    ///    `1 − disturbanceVegSuppress·disturb` skaliert (Rohboden ist kein
    ///    Standort) — dort, nicht hier, weil es ein Ziel-Effekt ist.
    ///
    /// Dazu kommt ein vierter Effekt, der schlicht ein ausgesetzter Aufräum-Pass
    /// ist, solange die Baustelle offen ist: die Pfützen-Verlandung
    /// (`fillShallowPonds`) schüttet das frische Mikro-Relief nicht wieder zu.
    ///
    /// Bewusst KEIN globaler Servo-Eingriff: die Alterung aus Issue #13 bleibt
    /// unangetastet (`reliefServoPer100y` unverändert).
    private func regenerateDisturbed(dt: Double) {
        guard cfg.disturbanceEnabled, disturbActive, dt > 0 else { return }
        let tau = max(1e-9, cfg.disturbanceRecoveryYears)
        let f = 1 - exp(-dt / tau)          // Anteil des Budgets, der diesen Schritt fällig ist
        var maxLeft = 0.0
        for k in 0..<cfg.count {
            let d = disturb[k]
            if d <= 0 { continue }
            let spend = regenPending[k] * f
            if spend != 0 {
                applyRegenDelta(k, spend)
                regenPending[k] -= spend
            }
            let left = d - d * f
            disturb[k] = left
            maxLeft = max(maxLeft, left)
        }
        if cfg.disturbanceMeanderDrop > 0 { dropDisturbedMeanderState() }
        // Ausgeklungen (< 1 % Reststörung ≈ 4.6 τ) → Pfad abschalten. Der Rest
        // des Budgets wird dabei VOLLSTÄNDIG eingetragen statt verworfen: so ist
        // die insgesamt eingetragene Geländeänderung exakt das gebuchte Budget,
        // egal wann die Abschaltung in einen Zeitschritt fällt.
        if maxLeft < 0.01 {
            for k in 0..<cfg.count {
                if regenPending[k] != 0 { applyRegenDelta(k, regenPending[k]) }
                disturb[k] = 0
                regenPending[k] = 0
            }
            disturbActive = false
        }
    }

    /// Höhenänderung des Regenerations-Passes mit Fels/Sediment-Buchhaltung.
    /// Wie `applyDelta`, aber OHNE erneute Störungs-Buchung (sonst hielte sich
    /// der Pfad selbst am Leben) und ohne den Werkzeug-Deckel bei 1.4.
    @inline(__always) private func applyRegenDelta(_ k: Int, _ dhRaw: Double) {
        let dh = max(h[k] + dhRaw, cfg.floor) - h[k]
        if dh >= 0 {
            rock[k] += dh
        } else {
            let ds = min(-dh, sed[k])
            sed[k] -= ds
            rock[k] -= (-dh - ds)
        }
        h[k] += dh
    }

    /// Verwirft Mäanderläufe und Altarme, die über stark gestörtes Gelände
    /// laufen: eine Zentrumslinie ist die Geschichte eines Betts, das es unter
    /// dem neuen Gelände nicht mehr gibt. `migrateMeander` sät danach aus der
    /// aktuellen Entwässerung neu — solange die Baustelle offen ist, wird also
    /// je Schritt frisch getrasst statt alter Zustand fortgeschrieben.
    private func dropDisturbedMeanderState() {
        let thr = cfg.disturbanceMeanderDrop
        func disturbed(_ nd: MeanderNode) -> Bool {
            let i = min(max(Int(nd.x.rounded()), 0), n - 1)
            let j = min(max(Int(nd.z.rounded()), 0), n - 1)
            return disturb[j * n + i] >= thr
        }
        meander.channels.removeAll { $0.nodes.contains(where: disturbed) }
        var keptOxbows: [[MeanderNode]] = []
        var keptAges: [Double] = []
        for (oi, ox) in meander.oxbows.enumerated() where !ox.contains(where: disturbed) {
            keptOxbows.append(ox)
            keptAges.append(oi < meander.oxbowAge.count ? meander.oxbowAge[oi] : 0)
        }
        meander.oxbows = keptOxbows
        meander.oxbowAge = keptAges
    }

    // MARK: - Mäander-Migration (Lagrange-Zentrumslinien)

    private func seedMeander() {
        meander.channels = MeanderState.traceChannels(config: cfg, h: h, hf: hf,
                                                       area: area, receiver: receiver)
        meander.oxbows.removeAll()
        meander.oxbowAge.removeAll()
    }

    /// Einzugsgebiet an einer kontinuierlichen Grid-Position (bilinear).
    @inline(__always) private func bilinearArea(_ gx: Double, _ gz: Double) -> Double {
        let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
        let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
        let k = yi * n + xi
        return area[k] * (1 - fx) * (1 - fy) + area[k + 1] * fx * (1 - fy)
             + area[k + n] * (1 - fx) * fy + area[k + n + 1] * fx * fy
    }

    /// Mittleres Auwald-veg im Ufer-Streifen (±meanderBankWidth, gerundet) um
    /// eine Knotenposition — Eingang der Mäander-Ufer-Kohäsion. Gemittelt wird
    /// über ALLE Streifen-Zellen (Auwald-fremde zählen 0): eine einzelne
    /// Auwald-Zelle bremst also kaum, ein voll bewachsener Streifen deutlich.
    func riparianVegAt(_ gx: Double, _ gz: Double) -> Double {
        let r = max(1, Int(cfg.meanderBankWidth.rounded()))
        let ci = min(max(Int(gx.rounded()), 0), n - 1)
        let cj = min(max(Int(gz.rounded()), 0), n - 1)
        var s = 0.0
        var cnt = 0
        for dj in max(0, cj - r)...min(n - 1, cj + r) {
            for di in max(0, ci - r)...min(n - 1, ci + r) {
                let k = dj * n + di
                cnt += 1
                if vegClass[k] == 3 { s += veg[k] }
            }
        }
        return cnt == 0 ? 0 : s / Double(cnt)
    }

    /// Geländehöhe an einer kontinuierlichen Grid-Position (bilinear).
    @inline(__always) private func bilinearH(_ gx: Double, _ gz: Double) -> Double {
        let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
        let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
        let k = yi * n + xi
        return h[k] * (1 - fx) * (1 - fy) + h[k + 1] * fx * (1 - fy)
             + h[k + n] * (1 - fx) * fy + h[k + n + 1] * fx * fy
    }

    /// Frischt den Abfluss entlang der Läufe aus dem aktuellen Einzugsgebiet auf
    /// und migriert sie einen Zeitschritt. Mobilität aus der lokalen Steigung:
    /// steile Oberläufe bleiben gerade, nur Flachland wandert. Degenerierte Läufe
    /// werden verworfen; ist nichts mehr da, aus der Entwässerung neu säen.
    private func migrateMeander(dt: Double) {
        if meander.channels.isEmpty { seedMeander(); return }
        let cellArea = cfg.cellSize * cfg.cellSize
        for ci in meander.channels.indices {
            for ni in meander.channels[ci].nodes.indices {
                let nd = meander.channels[ci].nodes[ni]
                meander.channels[ci].discharge[ni] = max(0, bilinearArea(nd.x, nd.z) / cellArea)
            }
        }
        meander.migrate(dt: dt, config: cfg,
                        heightAt: { self.bilinearH($0.x, $0.z) },
                        riparianAt: { self.riparianVegAt($0.x, $0.z) })
        // Sicherheits-Clamp: Knoten dürfen die Welt nicht verlassen.
        let maxc = Double(n - 1)
        for ci in meander.channels.indices {
            for ni in meander.channels[ci].nodes.indices {
                meander.channels[ci].nodes[ni].x = min(max(meander.channels[ci].nodes[ni].x, 0), maxc)
                meander.channels[ci].nodes[ni].z = min(max(meander.channels[ci].nodes[ni].z, 0), maxc)
            }
        }
        meander.channels.removeAll { $0.nodes.count < 3 }
        if meander.channels.isEmpty { seedMeander() }
    }

    // MARK: - Mäander-Kopplung ins Höhenfeld (M3)

    /// Trägt an Zelle `k` `amount` ab (erst Sediment, dann Fels) — hält
    /// h = rock + sed. Gibt den tatsächlich abgetragenen Betrag zurück.
    @inline(__always) private func erodeCell(_ k: Int, _ amount: Double) -> Double {
        let a = max(0, amount)
        if a <= 0 { return 0 }
        let ds = min(a, sed[k]); sed[k] -= ds
        rock[k] -= (a - ds)
        h[k] -= a
        return a
    }

    /// Lagert `amount` als Sediment an Zelle `k` ab.
    @inline(__always) private func depositCell(_ k: Int, _ amount: Double) {
        if amount <= 0 { return }
        sed[k] += amount; h[k] += amount
    }

    /// Stempelt die Mäander-Läufe ins Höhenfeld:
    /// 1) **Bett-Carve** (Kanal carvt selbst) — senkt die überstrichenen Zellen
    ///    Richtung stromab-Höhe, self-reinforcing mit D8 (nächstes computeFlow
    ///    routet durchs Bett). Gedeckelt aufs halbe lokale Gefälle.
    /// 2) **Laterale Ufer-Verschiebung** — Prallhang (Außenkurve) erodieren,
    ///    Gleithang (Innenkurve) ablagern, massenerhaltend. So wandert das Bett.
    /// 3) **isChannel-Maske** für die Reconciliation mit `transportLimited`.
    private func meanderStamp(dt: Double) {
        for k in 0..<cfg.count { isChannel[k] = false }
        let m = cfg.mExp
        let cs = cfg.cellSize
        let cellArea = cs * cs
        let width = cfg.meanderBankWidth
        for ch in meander.channels {
            let nodes = ch.nodes
            guard nodes.count >= 2 else { continue }
            // --- 1) Bett-Carve entlang der Segmente ---
            for i in 0..<(nodes.count - 1) {
                let a = nodes[i], b = nodes[i + 1]
                let d = dist(a, b)
                let hb = bilinearH(b.x, b.z)                      // stromab-Zielhöhe
                let ha = bilinearH(a.x, a.z)
                let segSlope = d > 1e-6 ? max(0, ha - hb) / (d * cs) : 0
                let qA = 0.5 * (ch.discharge[i] + ch.discharge[i + 1]) * cellArea // echtes A
                let carveRate = cfg.meanderCarve * pow(max(qA, 0), m) * segSlope * dt
                let steps = max(1, Int(d.rounded(.up)))
                for sIdx in 0...steps {
                    let t = Double(sIdx) / Double(steps)
                    let ci = min(max(Int((a.x + (b.x - a.x) * t).rounded()), 0), n - 1)
                    let cj = min(max(Int((a.z + (b.z - a.z) * t).rounded()), 0), n - 1)
                    let k = cj * n + ci
                    // Unter stehendem Wasser (See/geflutete Ebene) KEIN Bett-Carve und
                    // KEINE Kanal-Maske: dort fließt nichts (Stillwasser), und die Maske
                    // würde die Droplet-Deposition dämpfen — der Kanal grub sonst über
                    // Jahrtausende dunkle Tiefen-Rinnen in Seeböden, die nie verlanden
                    // (gemessen: hf−h > 0.16 nach 24k Jahren, „dunkle Stellen").
                    if hf[k] - h[k] > 0.02 { continue }
                    isChannel[k] = true
                    // Ufer-Kill (Stufe 3): das überstrichene Bett reißt die
                    // Wurzeln weg — veg hart auf 0 (absorbierend, dt-frei).
                    // Regrünung kommt per Sukzession von den Nachbarn zurück,
                    // sobald der Lauf weiterwandert.
                    veg[k] = 0
                    let cap = max(0, h[k] - hb) * 0.5             // nicht unter stromab graben
                    _ = erodeCell(k, min(carveRate, cap))
                }
            }
            // --- 2) laterale Ufer-Verschiebung pro innerem Knoten ---
            for i in 1..<(nodes.count - 1) {
                let a = nodes[i - 1], b = nodes[i], c = nodes[i + 1]
                let v1x = b.x - a.x, v1z = b.z - a.z
                let v2x = c.x - b.x, v2z = c.z - b.z
                let ds = 0.5 * ((v1x * v1x + v1z * v1z).squareRoot()
                              + (v2x * v2x + v2z * v2z).squareRoot())
                if ds < 1e-9 { continue }
                let cross = v1x * v2z - v1z * v2x
                let dot = v1x * v2x + v1z * v2z
                let curv = atan2(cross, dot) / ds
                let tx = c.x - a.x, tz = c.z - a.z
                let tl = (tx * tx + tz * tz).squareRoot()
                if tl < 1e-9 { continue }
                // Außen-Normale = weg vom Krümmungszentrum (−sign(curv) · linke Normale)
                let sgn = curv > 0 ? -1.0 : 1.0
                let ox = sgn * (-tz / tl), oz = sgn * (tx / tl)
                let outI = min(max(Int((b.x + ox * width).rounded()), 0), n - 1)
                let outJ = min(max(Int((b.z + oz * width).rounded()), 0), n - 1)
                let inI = min(max(Int((b.x - ox * width).rounded()), 0), n - 1)
                let inJ = min(max(Int((b.z - oz * width).rounded()), 0), n - 1)
                let ko = outJ * n + outI, ki = inJ * n + inI
                if ko == ki { continue }
                let qA = ch.discharge[i] * cellArea
                let want = cfg.meanderBankErode * pow(max(qA, 0), m) * abs(curv) * dt
                // nur so viel, dass der Prallhang nicht unter den Innenhang fällt
                let cap = max(0, h[ko] - h[ki]) * 0.5
                let moved = erodeCell(ko, min(want, cap))
                depositCell(ki, moved)
            }
        }
        plugOxbows()
        fillOxbows(dt: dt)
    }

    /// Altarm-Verlandung: hebt die Altarm-Betten langsam (Zeitkonstante
    /// `oxbowFillYears`) Richtung Uferrand an (Sediment) — der See verschwindet
    /// allmählich. Vollständig verlandete Altarme fallen aus der Liste.
    private func fillOxbows(dt: Double) {
        let rate = min(1.0, dt / cfg.oxbowFillYears)
        for loop in meander.oxbows {
            for nd in loop {
                let ci = min(max(Int(nd.x.rounded()), 1), n - 2)
                let cj = min(max(Int(nd.z.rounded()), 1), n - 2)
                let k = cj * n + ci
                var rim = h[k]
                for nb in [k - 1, k + 1, k - n, k + n] { rim = max(rim, h[nb]) }
                let add = (rim - h[k]) * rate
                if add > 0 { depositCell(k, add) }
            }
        }
        meander.pruneOxbows(maxAge: cfg.oxbowMaxAge)
    }

    /// Verkorkt frisch abgeschnürte Schleifen (Alter 0) an ihren Enden mit
    /// Sediment, sodass D8 nicht mehr hindurchroutet und die eingetiefte Schleife
    /// über den bestehenden `hf>h`-Mechanismus zum Altarm-See wird.
    private func plugOxbows() {
        for oi in meander.oxbows.indices where meander.oxbowAge[oi] == 0 {
            let loop = meander.oxbows[oi]
            guard loop.count >= 4 else { continue }
            for nd in [loop[1], loop[loop.count - 2]] {
                let ci = min(max(Int(nd.x.rounded()), 1), n - 2)
                let cj = min(max(Int(nd.z.rounded()), 1), n - 2)
                let k = cj * n + ci
                // auf den umgebenden Uferlippen-Pegel anheben → Schleife abgetrennt
                var lip = h[k]
                for nb in [k - 1, k + 1, k - n, k + n] { lip = max(lip, h[nb]) }
                depositCell(k, max(0, lip - h[k]))
            }
        }
    }

    // MARK: - Zeitschritt

    /// Simuliert `dtYears` Jahre. `dtYears` darf groß sein (Stream-Power ist
    /// implizit stabil); die Hangprozesse werden intern anteilig getaktet.
    public func step(dtYears dt: Double) {
        // Abklingende Hebung (post-orogener Zerfall, s. Config). Der Relief-Servo
        // ist nur noch UNTERGRENZE: er greift, wenn U(t) das Relief nicht mehr
        // über `reliefTarget` hält — im normalen 100k-Fenster nie (gemessen). Das
        // max steckt UNTER dem Integral (s. upliftAmount), sonst hinge der
        // Übergangsschritt an der Schrittweite.
        applyUplift(dt: dt, gatedAmount: upliftAmount(dt: dt,
                                                      floorPer100y: reliefServoRate()))
        // Regeneration frisch umgegrabener Flächen (Issue #26): trägt das
        // Mikro-Relief ein und räumt Mäander-/Altarmzustand ab, BEVOR der Flow
        // läuft — die Entwässerung dieses Schritts sieht das neue Gelände.
        // Ohne Störung (Normalfall) ein reiner Boolean-Test.
        regenerateDisturbed(dt: dt)
        // Gesteinsfeld (Issue #12) auf die frische Höhe nachziehen, BEVOR ein
        // Erosionspass es liest: die freigelegte Schicht folgt aus h, und h hat
        // sich gerade durch die Hebung verschoben. Reine Ableitung, kein Zustand —
        // die Reihenfolge im Schritt ist damit unkritisch, nur „vor der Erosion".
        updateLithology()
        flowStepCount &+= 1
        let mfdInterval = max(1, cfg.mfdUpdateInterval)
        // Braiding ist MFD-Physik, nicht bloß Rendering: dafür darf das Feld
        // niemals hinter dem aktuellen Terrain zurückbleiben.
        let updateMFD = cfg.braidingEnabled || Int(flowStepCount % UInt32(mfdInterval)) == 0
        computeFlow(includeMFD: updateMFD, dtYears: dt)
        relaxWaterLevel(dt: dt) // Seespiegel folgt dem frischen hf (s. Doku dort)
        updateSaltCrust(dt: dt) // Playa-Kruste folgt der frischen Becken-Rolle
        if cfg.meanderEnabled {
            migrateMeander(dt: dt) // Läufe evolvieren (Abfluss/Mobilität aus frischem Flow)
            meanderStamp(dt: dt)   // Bett-Carve + laterale Ufer + Altarm-Pfropf, setzt isChannel
        }
        let passes = max(1, Int((dt / 100).rounded()))
        if cfg.hydraulicEnabled {
            // Prozess-Reihenfolge (FastScape/LEM-Konvention, docs/research-terrain-aging.md §4):
            // Uplift → Flow (oben) → Stream-Power/Auslass (Makro-Täler) → Droplet (Textur)
            // → Hangdiffusion (Grate runden) → Wave.
            stepCount &+= 1
            // 1) Fluviale Makro-Inzision zuerst: schneidet das kohärente Talnetz und
            //    entwässert die Becken zum Meer, an dem die Hänge dann „hängen".
            if cfg.outletIncision { outletIncision(dt: dt) }
            if cfg.basinFill { fillLakes(dt: dt) } // Rest-Senken verlanden (Rückfall)
            if cfg.puddleFillYears > 0 { fillShallowPonds(dt: dt) }
            // 1b) Braiding: super-linearer Bedload-Transport auf dem MFD-Netz baut
            //     Mittelbänke/Fäden auf den großen Läufen (Verflechtung).
            if cfg.braidingEnabled { braidPass(dt: dt) }
            // 2) Droplet-Erosion legt die feine dendritische Textur (nickmcd-Look) hinein.
            // Tropfen ∝ Zeit × Fläche (Dichte kalibriert auf n = 640).
            let density = Double(n * n) / (640.0 * 640.0)
            let drops = max(1, Int(dt * cfg.hydraulicPerYear * density))
            let dropSeed = seed &+ stepCount &* 2_654_435_761
            for k in 0..<cfg.count { trackBuf[k] = 0 }
            // Kanalmaske mit: auf Mäanderbetten ist die Tropfen-DEPOSITION gedämpft
            // (Reconciliation — sonst schütten die Tropfen das gecarvte Bett wieder zu).
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: dropSeed, floor: cfg.floor, p: cfg.hydraulic,
                            seaLevel: cfg.hydraulicSkipWaterSpawns ? cfg.sea : nil,
                            hf: hf, receiver: receiver,
                            stream: streamMap,
                            channel: cfg.meanderEnabled ? isChannel : [],
                            rainWeight: rainWeight,
                            erodibility: lithErodeK,
                            track: &trackBuf)
            // Besuchs-RATE (Besuche/Jahr) glätten (nickmcd lrate, dt-skaliert,
            // Zeitkonstante aus `streamMapMemoryYears`), dann sättigen: nur KONSISTENT befahrene
            // Zellen hellen auf, einzelne Zufallspfade verblassen.
            // EWMA + Sättigung fusioniert und datenparallel (per-Zelle unabhängig,
            // bit-identisch zu „erst EWMA-Loop, dann deriveStreamMap").
            let lam = 1 - exp(-dt / cfg.streamMapMemoryYears)
            let r0 = cfg.streamRefRate
            streamRate.withUnsafeMutableBufferPointer { srb in
            streamMap.withUnsafeMutableBufferPointer { smb in
            trackBuf.withUnsafeBufferPointer { tbb in
                let psr = srb.baseAddress!, psm = smb.baseAddress!, ptb = tbb.baseAddress!
                parallel(cfg.count) { lo, hi in
                    for k in lo..<hi {
                        let v = (1 - lam) * psr[k] + lam * (ptb[k] / dt)
                        psr[k] = v
                        psm[k] = v / (v + r0)
                    }
                }
            }}}
            // 2b) Auen-Aggradation: Flüsse schütten seitlich flache Schwemmböden auf
            //     (bankfull) → breite Niedrig-Gradient-Reaches für Mäander/Braiding.
            //     Nach dem Carve (Bett steht), vor der Diffusion (glättet die Aue).
            if cfg.floodplainEnabled { floodplainAggradation(dt: dt) }
            // 3) Hangdiffusion (Bodenkriechen, D·∇²z): rundet Grate über die Zeit → altes
            // Terrain wird RUND statt immer spitzer (Appalachen-Signal, konvexe Kuppen).
            // Gesamtwirkung ∝ dt (chunking-/framerate-UNABHÄNGIG!): Echtzeit-Zeitraffer
            // (winziges dt/Frame) und große Sprünge (+10.000 J.) liefern dasselbe
            // Ergebnis. Früher lief die Diffusion je „Pass" (passes=max(1,dt/100)) →
            // bei dt≈0.2/Frame ~100× zu viel Rundung UND 100× zu viel Rechenzeit.
            // kappa auch auflösungs-unabhängig (∝ 1/dx² ∝ (n−1)², auf n=640 kalibriert).
            let refN = 639.0, m1 = Double(n - 1)
            let kYear = cfg.hillDiffusion * (m1 * m1) / (refN * refN) / 100.0 // war „kappa je 100-Jahr-Pass"
            let totalK = kYear * dt
            let nSub = max(1, Int((totalK / 0.2).rounded(.up)))   // stabil: Teilschritt-kappa ≤ 0.2
            let subK = totalK / Double(nSub)
            for _ in 0..<nSub { hillslopeDiffusion(base: subK) }
            let nWave = max(1, min(24, Int((dt / 100).rounded())))
            for _ in 0..<nWave { wavePass() }
        } else {
            transportLimited(dt: dt) // massenerhaltend; auf Kanalzellen gedämpft (Reconciliation)
            for _ in 0..<passes { diffusionPass(); wavePass() }
        }
        updateVegetation(years: dt)
        years += dt
    }

    /// Darstellungs-Seespiegel ratenbegrenzt Richtung Füllstand relaxieren
    /// (s. waterLevel-Doku). Exponentiell in Sim-Zeit → dt-invariant: Zeitraffer
    /// in Mini-Schritten und ein +10.000-J.-Sprung landen am selben Pegel.
    /// Per-Zelle unabhängig → parallel, bit-identisch zur sequenziellen Schleife.
    private func relaxWaterLevel(dt: Double) {
        guard cfg.lakeLevelResponseYears > 0 else { waterLevel = hf; return }
        let wlam = 1 - exp(-dt / cfg.lakeLevelResponseYears)
        waterLevel.withUnsafeMutableBufferPointer { wlb in
        hf.withUnsafeBufferPointer { hfb in
            let pwl = wlb.baseAddress!, phf = hfb.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi { pwl[k] += (phf[k] - pwl[k]) * wlam }
            }
        }}
    }

    // MARK: - Diagnose (für Tests & UI)

    /// Reliefspanne über Land (max − min der Landzellen). Reine ANZEIGE-/Test-
    /// Kennzahl: sie hängt an genau zwei Extremzellen (das Minimum liegt per
    /// Definition knapp über `sea`, also IST sie im Wesentlichen die Höhe des
    /// höchsten Punkts). Als Regelsignal ist sie deshalb ungeeignet — dafür
    /// `landReliefRobust()`.
    public func landRelief() -> Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for k in 0..<cfg.count where h[k] > cfg.sea {
            lo = min(lo, h[k]); hi = max(hi, h[k])
        }
        if hi < lo { return 0 }
        return hi - lo
    }

    /// Robuste Relief-Kennzahl: **95. Perzentil − Median der Landhöhen**, also
    /// die Spanne zwischen dem hohen und dem typischen Land. Sie ist
    /// das Regelsignal des Relief-Servos (Begründung + Messwerte: `Config.swift`
    /// bei `reliefTarget`): Einzelzellen (Nadelgipfel, Sculpt-Strich, tiefe
    /// Rinne) können sie nicht verschieben, weil beide Quantile aus zehntausenden
    /// Zellen kommen — gemessen (n=160, Seed 1337, 100k Jahre) verschiebt eine auf
    /// 1.4 gezogene Einzelzelle `landRelief()` von 0.5097 auf 1.2500 (+145 %),
    /// dieses Signal gar nicht (0.16211 → 0.16211): exakt gerechnet sind es
    /// +0.019 % (0.161965 → 0.161995) und damit weniger als eine Bin-Breite.
    public func landReliefRobust() -> Double {
        Terrain.landReliefRobust(heights: h, sea: cfg.sea)
    }

    /// Freie Funktion auf einem beliebigen Höhenfeld, damit Tests synthetische
    /// Felder (z. B. mit künstlichem Einzelgipfel) prüfen können, ohne das
    /// Terrain zu mutieren.
    public static func landReliefRobust(heights: [Double], sea: Double) -> Double {
        landHeightQuantiles(heights: heights, sea: sea).high
    }

    /// **Hochseitenrelief** = p95 − Median: wie weit steht das hohe Land über dem
    /// typischen? Identisch zu `landReliefRobust()` — das Regelsignal des Servos.
    public func landReliefHigh() -> Double { landReliefRobust() }

    /// **Talseitenrelief** = Median − p05: wie tief liegt das tiefe Land unter dem
    /// typischen? Die Gegenprobe zum Hochseitenrelief (Issue #26): eine
    /// eingeebnete Platte, in die sich Rinnen schneiden, differenziert sich
    /// ZUERST nach UNTEN — das Hochseitenrelief bleibt dabei lange bei ~0 und
    /// täuscht „keine Erholung" vor, während umgekehrt ein paar Rand- oder
    /// Rinnenzellen `landRelief()` (max−min) groß aussehen lassen, ohne dass
    /// sich die Fläche differenziert hätte. Erst BEIDE Seiten zusammen sagen,
    /// ob die Landschaft wieder Struktur hat.
    public func landReliefLow() -> Double {
        let q = Terrain.landHeightQuantiles(heights: h, sea: cfg.sea)
        return q.low
    }

    /// Beide robusten Relief-Halbseiten aus EINEM Histogramm-Pass:
    /// `high` = p95 − Median, `low` = Median − p05.
    public static func landHeightQuantiles(heights: [Double], sea: Double)
        -> (high: Double, low: Double) {
        // Histogramm statt Sortieren: die Kennzahl läuft in JEDEM Zeitschritt über
        // ~500k Landzellen (Frame-Budget!) — ein Zählpass ist O(N) und dazu exakt
        // deterministisch (Integer-Zählung, keine Reihenfolge-Effekte).
        // Spanne ab `sea` großzügig bis sea+2.0: die Sim deckelt Hebung bei
        // isoHighClamp (0.90), nur Sculpting kommt überhaupt in die Nähe. Höhere
        // Werte landen im letzten Bin — das kann das Signal nur dann sättigen,
        // wenn >5 % des Landes so hoch stehen (dann ist es real so hoch).
        // Preis: das Ergebnis ist auf Bin-Mitten quantisiert, die Kennzahl also
        // ein Vielfaches von span/bins = 0.000488. Das ist 1/140 der Regelspanne
        // (reliefServoBand 0.07) — für den Servo bedeutungslos, aber beim
        // Dokumentieren von Messwerten zu beachten: Unterschiede unterhalb einer
        // Bin-Breite zeigt diese Funktion als 0 (s. Nadel-Messung oben).
        let bins = 4096
        let span = 2.0
        var hist = [Int](repeating: 0, count: bins)
        var total = 0
        for v in heights where v > sea {
            let b = min(bins - 1, max(0, Int((v - sea) / span * Double(bins))))
            hist[b] += 1
            total += 1
        }
        guard total >= 20 else { return (0, 0) } // zu wenig Land für Quantile
        func quantile(_ p: Double) -> Double {
            let rank = Int((Double(total - 1) * p).rounded())
            var cum = 0
            for b in 0..<bins {
                cum += hist[b]
                if cum > rank { return sea + (Double(b) + 0.5) * span / Double(bins) }
            }
            return sea + span
        }
        let med = quantile(0.5)
        return (quantile(0.95) - med, med - quantile(0.05))
    }

    /// Aktuell wirkende Servo-Hebung (pro 100 Jahre) aus dem robusten Relief-
    /// Signal. EINZIGE Quelle für `step()` und die Diagnose-Anzeige — beide
    /// hatten die Formel früher dupliziert und konnten auseinanderlaufen.
    public func reliefServoRate() -> Double {
        guard cfg.reliefServoPer100y > 0, cfg.reliefServoBand > 0 else { return 0 }
        let deficit = cfg.reliefTarget - landReliefRobust()
        guard deficit > 0 else { return 0 }
        return cfg.reliefServoPer100y * min(1, deficit / cfg.reliefServoBand)
    }

    /// Aktuell wirkende Hebungsrate (pro 100 Jahre) der abklingenden Tektonik:
    /// `U(t) = U_floor + (U₀ − U_floor)·e^(−t/τ)` (docs/research-terrain-aging.md §3).
    /// Reine ANZEIGE-/Diagnose-Größe — `step()` integriert die Rate exakt über den
    /// Zeitschritt (`upliftAmount`), statt sie am Schrittanfang zu sampeln.
    public func upliftDecayRatePer100y() -> Double {
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        guard cfg.upliftDecayYears > 0 else { return u0 }
        return uFloor + (u0 - uFloor) * exp(-years / cfg.upliftDecayYears)
    }

    /// Über das ABSOLUTE Zeitintervall `[a, b]` (Sim-Jahre) exakt integrierte
    /// abklingende Hebung, in Höheneinheiten bei `upliftBase == 1`:
    ///
    ///     ∫ U(t) dt / 100 = [U_floor·(b−a) + (U₀ − U_floor)·τ·(e^(−a/τ) − e^(−b/τ))] / 100
    ///
    /// Die geschlossene Form (statt „Rate am Schrittanfang × dt") ist die
    /// Framerate-Unabhängigkeit dieses Passes: die Summe über viele Mini-Schritte
    /// teleskopiert exakt zum Wert EINES großen Sprungs — Echtzeit-Zeitraffer und
    /// „+10.000 Jahre" tragen dieselbe Hebung ein.
    private func upliftDecayIntegral(from a: Double, to b: Double) -> Double {
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        if u0 <= 0 && uFloor <= 0 { return 0 }
        let tau = cfg.upliftDecayYears
        guard tau > 0 else { return u0 * (b - a) / 100 } // τ = 0 → konstante Hebung
        let decayed = (u0 - uFloor) * tau * (exp(-a / tau) - exp(-b / tau))
        return (uFloor * (b - a) + decayed) / 100
    }

    /// Über `[years, years + dt]` integrierte abklingende Hebung — ohne
    /// Untergrenze (s. `upliftAmount(dt:floorPer100y:)`).
    func upliftDecayAmount(dt: Double) -> Double {
        upliftDecayIntegral(from: years, to: years + dt)
    }

    /// Die Hebung EINES Zeitschritts inklusive Servo-Untergrenze:
    ///
    ///     ∫ max(U(t), U_servo) dt / 100
    ///
    /// Das punktweise `max` unter dem Integral ist der Punkt: `max(∫U, U_servo·dt)`
    /// wäre schrittweiten-ABHÄNGIG. Schneidet U(t) die Untergrenze mitten in einem
    /// großen Schritt, gewinnt dort noch das Integral von U — bei kleineren
    /// Schritten übernähme im hinteren Teil bereits der Servo, und beide Wege
    /// lieferten verschiedene Ergebnisse (verletzt die Framerate-Invariante aus
    /// `AGENTS.md`). Der Schritt wird deshalb am SCHNITTPUNKT geteilt:
    ///
    ///     U(t*) = U_servo  ⇒  t* = −τ · ln((U_servo − U_floor) / (U₀ − U_floor))
    ///
    /// `t*` hängt nur von der Config ab, nicht von der Schrittweite — die Zerlegung
    /// ist damit über beliebige Unterteilungen additiv. (Die Servo-Rate selbst wird
    /// wie bei jedem Regler einmal pro Schritt aus dem aktuellen Relief gelesen;
    /// im Produktionsbetrieb ist sie über das ganze Alterungsfenster 0.)
    /// Wächter: `TerrainAging.testServoFloorCrossingIsFramerateIndependent`.
    func upliftAmount(dt: Double, floorPer100y: Double) -> Double {
        let a = years, b = years + dt
        let s = max(0, floorPer100y)
        if s <= 0 { return upliftDecayIntegral(from: a, to: b) }
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        let tau = cfg.upliftDecayYears
        // Kein Abklingen konfiguriert (τ ≤ 0 oder U₀ == U_floor) → die Rate ist über
        // den Schritt konstant U₀, das punktweise max also trivial.
        guard tau > 0, u0 != uFloor else { return max(u0, s) * (b - a) / 100 }
        func rate(_ t: Double) -> Double { uFloor + (u0 - uFloor) * exp(-t / tau) }
        let rA = rate(a), rB = rate(b)
        if min(rA, rB) >= s { return upliftDecayIntegral(from: a, to: b) } // ganz über der Grenze
        if max(rA, rB) <= s { return s * (b - a) / 100 }                   // ganz darunter
        // Genau ein Schnittpunkt (U ist streng monoton), garantiert in (a, b).
        let ratio = (s - uFloor) / (u0 - uFloor)
        let tStar = min(max(-tau * log(ratio), a), b)
        return u0 > uFloor
            ? upliftDecayIntegral(from: a, to: tStar) + s * (b - tStar) / 100  // fallend: erst U, dann Boden
            : s * (tStar - a) / 100 + upliftDecayIntegral(from: tStar, to: b)  // steigend: erst Boden, dann U
    }

    /// **Mittlere Grat-Krümmung** — die in `docs/research-terrain-aging.md` §6 als
    /// fehlend benannte Alterungs-Diagnose. Mittelwert des diskreten Laplace
    /// `∇²z = (z_l + z_r + z_o + z_u − 4z) / dx²` über die GRAT-Zellen, definiert
    /// als Landzellen nahe der Wasserscheide: Einzugsgebiet ≤ `maxAreaCells`
    /// Zellen (Default 2 — die Zelle selbst plus höchstens ein Zubringer).
    ///
    /// Das Vorzeichen trägt die Aussage: **negativ = konvex** (Material verlassend,
    /// „Kuppe"). Ein junger, spitzer Kamm ist ein schmaler Knick → stark negativ;
    /// die lineare Hangdiffusion arbeitet genau proportional zu dieser Größe und
    /// treibt sie gegen 0 → **betragsmäßig kleiner = runder = älter**. Damit
    /// trennt die Kennzahl „jung spitz" von „alt rund" objektiv, was `landRelief()`
    /// allein nicht kann (ein flaches Terrain kann trotzdem spitze Grate haben).
    ///
    /// Auflösungs-Hinweis: `dx` folgt `cfg.cellSize`, die Feature-Skala des
    /// Generators dagegen dem Grid (`baseFreq / n`) — der ABSOLUTE Wert ist
    /// deshalb nur bei gleichem `n` vergleichbar. Als Alterungs-Signal wird sie
    /// über die ZEIT bei festem `n` gelesen.
    ///
    /// Achtung beim FRISCH generierten Terrain (t = 0): dort dominiert die
    /// Zell-Rauigkeit der Noise-Oberfläche, und ÷dx² verstärkt sie mit steigender
    /// Auflösung (gemessen Seed 1337: −0.045 bei n=160, −0.143 bei n=320, −0.977
    /// bei n=832; nach den ersten ~20k Sim-Jahren liegen alle drei bei −0.03 …
    /// −0.05). Für Alterungs-Vergleiche deshalb erst NACH dem Einschwingen der
    /// frischen Oberfläche ablesen.
    public func ridgeCurvature(maxAreaCells: Double = 2) -> Double {
        let cellArea = cfg.cellSize * cfg.cellSize
        let limit = maxAreaCells * cellArea
        var sum = 0.0
        var count = 0
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let k = j * n + i
                guard h[k] > cfg.sea, area[k] <= limit else { continue }
                sum += (h[k - 1] + h[k + 1] + h[k - n] + h[k + n] - 4 * h[k]) / cellArea
                count += 1
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    public func maxHeight() -> Double { h.max() ?? 0 }
    public func minHeight() -> Double { h.min() ?? 0 }

    /// Gesamtes Einzugsgebiet, das an allen Senken (Meer + Ränder) ankommt.
    /// Muss der Gesamtzellzahl entsprechen: jede Zelle trägt genau ihre eigene
    /// Fläche bei und fließt zu genau einer Senke (Entwässerungs-Invariante).
    /// Gilt mit `cfg.rainWeightedFlow` UNVERÄNDERT: das Gewicht hat auf Land das
    /// Mittel 1 und über See exakt 1.0, Σ Startwerte bleibt also die Zellzahl
    /// (s. `updateRainWeight`; Wächter `testWeightedFlowKeepsDrainageTotal`).
    public func totalOutletArea() -> Double {
        let cellArea = cfg.cellSize * cfg.cellSize
        var sum = 0.0
        for k in 0..<cfg.count where receiver[k] < 0 {
            sum += area[k]
        }
        return sum / cellArea
    }

    public func landCellCount() -> Int {
        var c = 0
        for k in 0..<cfg.count where hf[k] > cfg.sea { c += 1 }
        return c
    }

    /// Anteil der Zellen, deren Empfänger sich gegenüber `other` NICHT geändert
    /// hat — misst die Fluss-Stabilität zwischen zwei Zuständen.
    public func receiverAgreement(with other: [Int32]) -> Double {
        var same = 0, total = 0
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            total += 1
            if receiver[k] == other[k] { same += 1 }
        }
        return total == 0 ? 1 : Double(same) / Double(total)
    }

    public func snapshotReceivers() -> [Int32] { receiver }
}

extension Double {
    @inline(__always) func magnitudeHypot(_ y: Double) -> Double {
        (self * self + y * y).squareRoot()
    }
}
