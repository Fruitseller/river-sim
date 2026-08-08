import Foundation

/// Der Simulationskern: hält alle Felder und führt die Landschaftsentwicklung
/// aus. Kennt bewusst KEIN Godot — dadurch headless mit XCTest testbar.
///
/// Erosionsmodell: FastScape-Stream-Power (detachment-limited, impliziter
/// n=1-Solver, unbedingt stabil bei großen Zeitschritten) für die fluviale
/// Inzision, kombiniert mit thermischer Hang-Diffusion (Talus). Entwässerung
/// über Priority-Flood (Barnes et al.) → füllt Senken, damit Flüsse bis zum
/// Meer routen; Seen = Zellen mit Füllhöhe > Geländehöhe.
public final class Terrain {
    public let cfg: SimConfig
    private let n: Int

    // Kernfelder
    public private(set) var h: [Double]      // Geländehöhe (rock + sed)
    public private(set) var rock: [Double]   // hartes Grundgestein
    public private(set) var sed: [Double]    // lockeres Sediment
    public private(set) var upliftBase: [Double] // tektonisches Feld (±, fix je Terrain)
    public private(set) var rain: [Double]   // Luftfeuchte/Niederschlag
    public private(set) var veg: [Double]    // Vegetationsdichte 0..1

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
    public private(set) var receiver: [Int32] // Abfluss-Nachbar (-1 = Senke/Meer)
    public private(set) var area: [Double]   // Einzugsgebiet (Zellflächen, Single-Flow/D8 → Erosion)
    public private(set) var areaMFD: [Double] // Multi-Flow-Einzugsgebiet (Freeman) → NUR Render/Braiding, nie Erosion
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
        hf = .init(repeating: 0, count: c)
        waterLevel = .init(repeating: 0, count: c)
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
                            stream: streamMap, track: &trackBuf)
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
    private func breachBasins() {
        for _ in 0..<cfg.breachMaxRounds {
            let s = lakeStats()
            let land = Double(landCellCount())
            // Fertig, wenn der See-Anteil klein ist UND kein einzelner See mehr
            // dominiert (diskrete nickmcd-Seen statt Zentralbecken).
            if s.fraction < cfg.breachTargetLakeFrac && Double(s.largest) < 0.025 * land { break }
            outletIncision(dt: cfg.breachDT, minAreaCells: 100)
            priorityFlood()
            computeReceiversAndArea()
        }
        computeFlow()
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
    }

    // MARK: - Vegetation

    public func updateVegetation(years: Double) {
        let f = min(1, years / cfg.vegTimeConstant)
        let nn = n, sea = cfg.sea
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        rain.withUnsafeBufferPointer { rnb in
        veg.withUnsafeMutableBufferPointer { vb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let prain = rnb.baseAddress!, pveg = vb.baseAddress!
            // Schreibt nur veg[k] → zeilenparallel, bit-identisch.
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
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
                    }
                    pveg[k] += (target - pveg[k]) * f
                }
            }
            }
        }}}}
    }

    // MARK: - Priority-Flood + Entwässerung (D8)

    /// Füllt Senken (Barnes et al.), bestimmt Abfluss-Nachbarn (steilster Abstieg
    /// auf der gefüllten Oberfläche) und akkumuliert das Einzugsgebiet.
    public func computeFlow(includeMFD: Bool = true) {
        computeRain()
        priorityFlood()
        computeReceiversAndArea()
        if includeMFD { computeMFDArea() }
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
            let phf = hfb.baseAddress!, prec = rb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!
            prec.update(repeating: -1, count: cnt)
            pa.update(repeating: cellArea, count: cnt)
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
                    if best < 0 { best = ppar[k] } // flacher Seespiegel → Überlauf
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
        }}}}}
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
        // Nachbar-Puffer auf dem Stack (die alten [Int]/[Double] kosteten je
        // Zugriff Bounds- + COW-Prüfung).
        withUnsafeTemporaryAllocation(of: Int32.self, capacity: 8) { nbK in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbW in
            let phf = hfb.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!
            pa.update(repeating: cellArea, count: cnt)
            var oi = cnt - 1
            while oi >= 0 {
                let k = Int(pord[oi]); oi -= 1
                let hk = phf[k]
                if hk <= sea { continue } // Meer = Senke, reicht nicht weiter
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
                    // Fläche nicht am See versickert.
                    let fp = ppar[k]
                    if fp >= 0 { pa[Int(fp)] += a }
                    continue
                }
                for t in 0..<c { pa[Int(nbK[t])] += a * (nbW[t] / wsum) }
            }
        }}}}}}}
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
                let want = (qcTot - qin) * (1 - 0.6 * veg[k])
                let er = erodeCell(k, min(want, max(0, h[k] - lowest) * 0.5))
                qout += er
            }
            // Fracht folgt der Kapazität (∝ qcᵢ): der starke Faden trägt sie weiter.
            if qout > 0 && qcTot > 1e-30 {
                for t in 0..<cnt { qs[nbK[t]] += qout * (nbQc[t] / qcTot) }
            }
        }
    }

    // MARK: - Stream-Power-Inzision (impliziter FastScape-Solver, n = 1)

    /// Löst dz/dt = −K·A^m·S über einen Zeitschritt `dt` (Jahre) implizit.
    /// Verarbeitet Zellen stromabwärts→stromaufwärts (order = aufsteigende
    /// Füllhöhe), sodass der Empfänger schon aktualisiert ist. Unbedingt stabil.
    private func streamPower(dt: Double) {
        let cs = cfg.cellSize
        let sqrt2 = 2.0.squareRoot()
        for oi in 0..<cfg.count {
            let k = Int(order[oi])
            let r = receiver[k]
            if r < 0 { continue }
            if h[k] <= cfg.sea { continue } // Meer nicht einschneiden
            let ri = Int(r)
            let hr = h[ri]
            if h[k] <= hr { continue } // See/Ebene: keine Inzision (Ablagerungs-Regime)
            let ki = k % n, kj = k / n
            let rii = ri % n, rjj = ri / n
            let dist = (ki != rii && kj != rjj) ? cs * sqrt2 : cs
            // Erodierbarkeit von der Sedimentdecke abhängig (Cover-Effekt):
            let kErode = sed[k] > cfg.sedCoverThresh ? cfg.kSed : cfg.kRock
            let kRed = kErode * (1 - 0.6 * veg[k]) // Vegetation schützt
            let f = kRed * dt * pow(area[k], cfg.mExp) / dist
            let hNew = (h[k] + f * hr) / (1 + f)
            var delta = h[k] - hNew // > 0
            if delta <= 0 { continue }
            // Abtrag: erst Sediment, dann Fels (bleibt konsistent: h = rock + sed).
            let ds = min(delta, sed[k])
            sed[k] -= ds
            delta -= ds
            rock[k] -= delta
            h[k] = hNew
        }
    }

    // MARK: - Transport-limitierte Fluss-Erosion (SPACE-artig)

    /// Massenerhaltender Sedimenttransport: der Fluss trägt eine Fracht `qs` und
    /// gleicht sie an die Transportkapazität Qc = Kt·Aᵐ·S an. Über Kapazität →
    /// Ablagerung (Deltas an Küsten, Schwemmebenen, Beckenfüllung); unter Kapazität
    /// → Erosion (detachment-begrenzt). Ersetzt die detachment-limited Inzision +
    /// den fillLakes-Hack. Verarbeitung stromauf→stromab (order rückwärts), sodass
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
                let kErode = (sed[k] > cfg.sedCoverThresh ? cfg.kSed : cfg.kRock) * (1 - 0.6 * veg[k])
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

    // MARK: - Thermische Erosion (Hang-Diffusion / Talus)

    private func thermalPass() {
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                // Oberhalb der Baumgrenze rutschen Hänge früher (Frost, kein Bewuchs).
                let tal = h[k] > 0.4 ? max(0.004, cfg.talus - (h[k] - 0.4) * 0.02) : cfg.talus
                var bestIdx = -1
                var bestDrop = tal
                if i > 0 { let d = h[k] - h[k - 1]; if d > bestDrop { bestDrop = d; bestIdx = k - 1 } }
                if i < n - 1 { let d = h[k] - h[k + 1]; if d > bestDrop { bestDrop = d; bestIdx = k + 1 } }
                if j > 0 { let d = h[k] - h[k - n]; if d > bestDrop { bestDrop = d; bestIdx = k - n } }
                if j < n - 1 { let d = h[k] - h[k + n]; if d > bestDrop { bestDrop = d; bestIdx = k + n } }
                if bestIdx >= 0 {
                    let move = (bestDrop - tal) * 0.5 * cfg.thermalRelax
                    let ms = min(move, sed[k])
                    let mr = (move - ms) * min(0.85, cfg.rockCrumble + 2.0 * max(0, h[k] - 0.45))
                    sed[k] -= ms
                    rock[k] -= mr
                    h[k] -= ms + mr
                    sed[bestIdx] += ms + mr
                    h[bestIdx] += ms + mr
                }
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
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rkb in
        veg.withUnsafeBufferPointer { vb in
        area.withUnsafeBufferPointer { ab in
        order.withUnsafeBufferPointer { ob in
        receiver.withUnsafeBufferPointer { rb in
            let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rkb.baseAddress!
            let pveg = vb.baseAddress!, pa = ab.baseAddress!
            let pord = ob.baseAddress!, prec = rb.baseAddress!
        // Stromabwärts→aufwärts (order = aufsteigende Füllhöhe): der Empfänger ist
        // schon aktualisiert, die Inzision propagiert sill-erhaltend flussaufwärts.
        for oi in 0..<cnt {
            let k = Int(pord[oi])
            let r = prec[k]
            if ph[k] <= sea { continue }            // Meer nicht einschneiden
            if pa[k] < minA { continue }            // Breach: nur das Trunk-Netz
            let hr: Double
            let dist: Double
            if r < 0 {
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
            let kErode = kOut * (1 - 0.6 * pveg[k]) // Vegetation bremst
            let f = kErode * dt * pow(pa[k], m) / dist
            let hNew = (ph[k] + f * hr) / (1 + f)
            var delta = ph[k] - hNew                // > 0
            if delta <= 0 { continue }
            let ds = min(delta, psed[k])            // erst Sediment, dann Fels
            psed[k] -= ds; delta -= ds
            prock[k] -= delta
            ph[k] = hNew
        }
        }}}}}}}
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
        for s in 0..<cfg.count where !pondSeen[s] && hf[s] > sea && hf[s] - h[s] > 0.001 {
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
    @inline(__always) private func pondPush(_ k: Int, _ stack: inout [Int32]) {
        if !pondSeen[k] && hf[k] > cfg.sea && hf[k] - h[k] > 0.001 {
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

    // MARK: - Hangdiffusion (linear)

    /// Lineare Diffusion dh/dt = D·∇²h — glatte, natürliche Hänge (konkav/konvex)
    /// statt der planaren Facetten/Terrassen der Schwellen-Talus-Methode.
    /// kappa fix bei 0.15 (< 0.25 → explizit stabil), mehrmals pro Sim-Schritt.
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
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rkb in
        veg.withUnsafeBufferPointer { vb in
        scratch.withUnsafeMutableBufferPointer { scb in
            let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rkb.baseAddress!
            let pveg = vb.baseAddress!, psc = scb.baseAddress!
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
                    let localK = base * (1 - 0.92 * bare)        // dort bis auf 8% gedrosselt (Gipfel bleiben spitz)
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
        }}}}}
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

    private func applyUplift(dt: Double, servoPer100y: Double = 0) {
        let uf = cfg.upliftPer100y * dt / 100
        // Servo NUR über den POSITIVEN Teil des Tektonik-Felds und NUR auf LAND:
        // er soll Grate nachwachsen lassen. Mit vollem upliftBase (Täler negativ)
        // SENKTE er die Täler unter den Meeresspiegel (halbe Insel geflutet);
        // ohne Land-Gate hob er den SCHELF in Tektonik-Ringen über die
        // Wasserlinie (grüne Kratersäume vor der Küste — beides gemessen).
        let us = servoPer100y * dt / 100
        if uf == 0 && us == 0 { return }
        for k in 0..<cfg.count {
            let servoK = (us > 0 && h[k] > cfg.sea) ? max(0, upliftBase[k]) * us : 0
            let du0 = upliftBase[k] * uf + servoK
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
        meander.migrate(dt: dt, config: cfg) { self.bilinearH($0.x, $0.z) }
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
        // Relief-Servo: Hebung nur bei Relief-Defizit (Anti-Verflachung, s. Config).
        var servo = 0.0
        if cfg.reliefServoPer100y > 0 {
            let deficit = cfg.reliefTarget - landRelief()
            if deficit > 0 { servo = cfg.reliefServoPer100y * min(1, deficit / 0.1) }
        }
        applyUplift(dt: dt, servoPer100y: servo)
        flowStepCount &+= 1
        let mfdInterval = max(1, cfg.mfdUpdateInterval)
        // Braiding ist MFD-Physik, nicht bloß Rendering: dafür darf das Feld
        // niemals hinter dem aktuellen Terrain zurückbleiben.
        let updateMFD = cfg.braidingEnabled || Int(flowStepCount % UInt32(mfdInterval)) == 0
        computeFlow(includeMFD: updateMFD)
        relaxWaterLevel(dt: dt) // Seespiegel folgt dem frischen hf (s. Doku dort)
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

    /// Reliefspanne über Land (max − min der Landzellen).
    public func landRelief() -> Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for k in 0..<cfg.count where h[k] > cfg.sea {
            lo = min(lo, h[k]); hi = max(hi, h[k])
        }
        if hi < lo { return 0 }
        return hi - lo
    }

    public func maxHeight() -> Double { h.max() ?? 0 }
    public func minHeight() -> Double { h.min() ?? 0 }

    /// Gesamtes Einzugsgebiet, das an allen Senken (Meer + Ränder) ankommt.
    /// Muss der Gesamtzellzahl entsprechen: jede Zelle trägt genau ihre eigene
    /// Fläche bei und fließt zu genau einer Senke (Entwässerungs-Invariante).
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
