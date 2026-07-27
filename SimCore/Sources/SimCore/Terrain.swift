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
    public private(set) var receiver: [Int32] // Abfluss-Nachbar (-1 = Senke/Meer)
    public private(set) var area: [Double]   // Einzugsgebiet (Zellflächen, Single-Flow/D8 → Erosion)
    public private(set) var areaMFD: [Double] // Multi-Flow-Einzugsgebiet (Freeman) → NUR Render/Braiding, nie Erosion
    private var order: [Int32]               // Pop-Reihenfolge (aufsteigende Füllhöhe)
    private var floodParent: [Int32]

    private var heap: MinHeap
    private var visited: [Bool]
    private var scratch: [Double] // Arbeitspuffer für die Diffusion
    private var qs: [Double]      // Sedimentfracht in Transit (transport-limitiert)
    private var isChannel: [Bool] // Zellen unter einer Mäander-Zentrumslinie (M3-Maske)
    private var noise: SimplexNoise

    /// Wandernde Fluss-Zentrumslinien (Mäander-Migration). In M2 noch entkoppelt
    /// vom Höhenfeld: sie evolvieren mit der Zeit, formen `h` aber noch nicht
    /// (das macht `meanderStamp` ab M3).
    public private(set) var meander = MeanderState()

    public private(set) var years: Double = 0
    private var seed: UInt32
    private var stepCount: UInt32 = 0 // deterministischer Zähler für die Droplet-Seeds

    public init(config: SimConfig = SimConfig(), seed: UInt32 = 1337) {
        self.cfg = config
        self.n = config.n
        self.seed = seed
        let c = config.count
        h = .init(repeating: 0, count: c)
        rock = .init(repeating: 0, count: c)
        sed = .init(repeating: 0, count: c)
        upliftBase = .init(repeating: 0, count: c)
        rain = .init(repeating: 0, count: c)
        veg = .init(repeating: 0, count: c)
        hf = .init(repeating: 0, count: c)
        receiver = .init(repeating: -1, count: c)
        area = .init(repeating: 0, count: c)
        areaMFD = .init(repeating: 0, count: c)
        order = .init(repeating: 0, count: c)
        floodParent = .init(repeating: -1, count: c)
        visited = .init(repeating: false, count: c)
        scratch = .init(repeating: 0, count: c)
        qs = .init(repeating: 0, count: c)
        isChannel = .init(repeating: false, count: c)
        heap = MinHeap(capacity: c)
        noise = SimplexNoise(seed: seed)
        generate(seed: seed)
    }

    @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { j * n + i }

    // MARK: - Terrain-Generierung

    public func generate(seed: UInt32) {
        self.seed = seed
        self.years = 0
        self.stepCount = 0
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
        initLayers()
        computeFlow()
        // Vegetation im eingeschwungenen Zustand starten.
        updateVegetation(years: 10000)
        seedMeander()
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
        for j in 0..<n {
            var m = 1.0
            for i in 0..<n {
                let k = idx(i, j)
                if h[k] <= cfg.sea {
                    m = min(1, m + 0.015) // über Wasser auftanken
                    rain[k] = m
                    continue
                }
                rain[k] = m
                let uph = i > 0 ? max(0, h[k] - h[k - 1]) : 0
                m = max(0.05, m - m * (0.0012 + uph * 1.5))
            }
        }
    }

    // MARK: - Vegetation

    public func updateVegetation(years: Double) {
        let f = min(1, years / cfg.vegTimeConstant)
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let k = idx(i, j)
                var target = 0.0
                let v = h[k]
                if v > cfg.sea + 0.005 && v < 0.68 && hf[k] - h[k] <= 0.015 {
                    let slope = (abs(h[k + 1] - h[k - 1]) + abs(h[k + n] - h[k - n])) * 0.25
                    let slopeOk = max(0, 1 - slope * 40)
                    let wet = min(1, rain[k] * 1.3)
                    let altOk = v < 0.5 ? 1 : max(0, 1 - (v - 0.5) / 0.18) // Wald wächst höher
                    target = slopeOk * wet * altOk
                }
                veg[k] += (target - veg[k]) * f
            }
        }
    }

    // MARK: - Priority-Flood + Entwässerung (D8)

    /// Füllt Senken (Barnes et al.), bestimmt Abfluss-Nachbarn (steilster Abstieg
    /// auf der gefüllten Oberfläche) und akkumuliert das Einzugsgebiet.
    public func computeFlow() {
        computeRain()
        priorityFlood()
        computeReceiversAndArea()
        computeMFDArea()
    }

    private func priorityFlood() {
        heap.removeAll()
        for k in 0..<cfg.count { visited[k] = false }
        // Ränder als Startpunkte (Meer/Weltrand = Basisniveau).
        for i in 0..<n {
            for b in [i, (n - 1) * n + i, i * n, i * n + n - 1] {
                if !visited[b] {
                    visited[b] = true
                    hf[b] = h[b]
                    floodParent[b] = -1
                    heap.push(key: hf[b], cell: Int32(b))
                }
            }
        }
        var oi = 0
        while !heap.isEmpty {
            let c = Int(heap.pop())
            order[oi] = Int32(c); oi += 1
            let ci = c % n, cj = c / n
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = ci + di, nj = cj + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    if visited[nb] { continue }
                    visited[nb] = true
                    hf[nb] = max(h[nb], hf[c])
                    floodParent[nb] = Int32(c)
                    heap.push(key: hf[nb], cell: Int32(nb))
                }
            }
        }
    }

    private func computeReceiversAndArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        for k in 0..<cfg.count {
            receiver[k] = -1
            area[k] = cellArea
        }
        // Empfänger: steilster Abstieg auf hf; auf Seespiegel-Flächen Richtung Überlauf.
        for k in 0..<cfg.count {
            if hf[k] <= cfg.sea { continue } // Meer = Senke
            let i = k % n, j = k / n
            var best: Int32 = -1
            var bestSlope = 0.0
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    let dist = (di != 0 && dj != 0) ? 2.0.squareRoot() : 1.0
                    let s = (hf[k] - hf[nb]) / dist
                    if s > bestSlope { bestSlope = s; best = Int32(nb) }
                }
            }
            if best < 0 { best = floodParent[k] } // flacher Seespiegel → Überlauf
            receiver[k] = best
        }
        // Einzugsgebiet: von hoch nach tief (order rückwärts) an Empfänger weiterreichen.
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(order[oi]); oi -= 1
            let r = receiver[k]
            if r >= 0 { area[Int(r)] += area[k] }
        }
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
        let minA = cfg.braidMinCells * cfg.cellSize * cfg.cellSize
        let flatCell = cfg.meanderFlatSlope * cfg.cellSize // Weltslope in Zell-Einheiten
        return (areaMFD[k] >= minA && sMax < flatCell && hf[k] - h[k] < 0.005)
             ? cfg.braidDispersion : cfg.mfdExponent
    }

    private func computeMFDArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let sqrt2 = 2.0.squareRoot()
        for k in 0..<cfg.count { areaMFD[k] = cellArea }
        var nbK = [Int](repeating: 0, count: 8) // wiederverwendete Nachbar-Puffer (keine Alloc je Zelle)
        var nbW = [Double](repeating: 0, count: 8)
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(order[oi]); oi -= 1
            if hf[k] <= cfg.sea { continue } // Meer = Senke, reicht nicht weiter
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
                    if s > 0 { nbK[cnt] = nb; nbW[cnt] = s; sMax = max(sMax, s); cnt += 1 }
                }
            }
            // areaMFD[k] ist beim Verarbeiten schon vollständig akkumuliert
            // (alle Zuflüsse liegen höher in hf) → das Gate im Exponenten-
            // Helfer ist gültig.
            let p = mfdLocalExponent(k, sMax: sMax)
            var wsum = 0.0
            for t in 0..<cnt { nbW[t] = pow(nbW[t], p); wsum += nbW[t] }
            if cnt == 0 || wsum <= 0 {
                // flache Seespiegel-Zelle (kein tieferer Nachbar) → wie D8 über den
                // Priority-Flood-Überlauf (floodParent) weiterreichen, damit die
                // Fläche nicht am See versickert.
                let fp = floodParent[k]
                if fp >= 0 { areaMFD[Int(fp)] += areaMFD[k] }
                continue
            }
            let a = areaMFD[k]
            for t in 0..<cnt { areaMFD[nbK[t]] += a * (nbW[t] / wsum) }
        }
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
            for t in 0..<cnt { nbW[t] = pow(nbS[t], p); wsum += nbW[t] }
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
    private func outletIncision(dt: Double) {
        let cs = cfg.cellSize
        let sqrt2 = 2.0.squareRoot()
        let m = cfg.mExp
        // Stromabwärts→aufwärts (order = aufsteigende Füllhöhe): der Empfänger ist
        // schon aktualisiert, die Inzision propagiert sill-erhaltend flussaufwärts.
        for oi in 0..<cfg.count {
            let k = Int(order[oi])
            let r = receiver[k]
            if r < 0 { continue }
            if h[k] <= cfg.sea { continue }         // Meer nicht einschneiden
            let ri = Int(r)
            if h[k] <= h[ri] { continue }           // See/Ebene: kein Gefälle → keine Inzision
            let i = k % n, j = k / n
            let rii = ri % n, rjj = ri / n
            let dist = (i != rii && j != rjj) ? cs * sqrt2 : cs
            // Reine Flächen-Stream-Power: die Inzision konzentriert sich auf Zellen mit
            // großem Einzugsgebiet (Täler/Auslässe) und lässt Grate in Ruhe → dendritisch
            // statt verrauscht. Ein Becken-Auslass sammelt das ganze Becken → tieft zügig
            // ein → See entwässert zum Meer.
            let kErode = cfg.outletErode * (1 - 0.6 * veg[k]) // Vegetation bremst
            let f = kErode * dt * pow(area[k], m) / dist
            let hNew = (h[k] + f * h[ri]) / (1 + f)
            var delta = h[k] - hNew                 // > 0
            if delta <= 0 { continue }
            let ds = min(delta, sed[k])             // erst Sediment, dann Fels
            sed[k] -= ds; delta -= ds
            rock[k] -= delta
            h[k] = hNew
        }
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
    private func hillslopeDiffusion(base: Double) {
        if base <= 0 { return }
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let hl = i > 0 ? h[k - 1] : h[k]
                let hr = i < n - 1 ? h[k + 1] : h[k]
                let hd = j > 0 ? h[k - n] : h[k]
                let hu = j < n - 1 ? h[k + n] : h[k]
                let lap = hl + hr + hd + hu - 4 * h[k]
                // Kahler-Fels-Faktor: hoch (h>0.5), steil und unbewachsen → wenig
                // Kriechen. Sediment/Vegetation heben das Kriechen wieder an.
                let gx = (hr - hl) * 0.5, gy = (hu - hd) * 0.5
                let slope = (gx * gx + gy * gy).squareRoot()
                let steep = min(1, slope * 26)               // etwas früher „steil" → mehr Grate bleiben scharf
                let high = min(1, max(0, (h[k] - 0.42) / 0.35)) // Schutz schon ab mittlerer Höhe
                let soil = min(1, sed[k] / 0.02 + veg[k])   // Boden ODER Bewuchs → Kriechen
                let bare = steep * high * max(0, 1 - soil)   // 1 = kahler steiler Hochfels
                let localK = base * (1 - 0.92 * bare)        // dort bis auf 8% gedrosselt (Gipfel bleiben spitz)
                scratch[k] = localK * lap
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

    private func applyUplift(dt: Double) {
        let uf = cfg.upliftPer100y * dt / 100
        if uf == 0 { return }
        for k in 0..<cfg.count {
            let du0 = upliftBase[k] * uf
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
    public func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        let rCells = radiusWorld / cfg.cellSize
        if rCells <= 0 { return }
        let rate = 0.006
        let coupling = 1.5
        let r = Int(rCells.rounded(.up))
        let cx = Int(gx.rounded()), cz = Int(gz.rounded())
        let jLo = max(0, cz - r), jHi = min(n - 1, cz + r)
        let iLo = max(0, cx - r), iHi = min(n - 1, cx + r)
        if jLo > jHi || iLo > iHi { return }
        for j in jLo...jHi {
            for i in iLo...iHi {
                let d = (Double(i) - gx).magnitudeHypot(Double(j) - gz) / rCells
                if d > 1 { continue }
                let w = (1 - d * d) * (1 - d * d) // weicher Abfall
                let k = idx(i, j)
                let target = min(max(h[k] + dir * rate * w, cfg.floor), 1.4)
                let dh = target - h[k]
                if dh >= 0 {
                    rock[k] += dh // Anheben schiebt Fels hoch
                } else {
                    let ds = min(-dh, sed[k]) // Absenken räumt erst Sediment, dann Fels
                    sed[k] -= ds
                    rock[k] -= (-dh - ds)
                }
                h[k] += dh
                upliftBase[k] = min(max(upliftBase[k] + dir * rate * w * coupling, -2), 2)
            }
        }
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
        applyUplift(dt: dt)
        computeFlow()
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
            // 1b) Braiding: super-linearer Bedload-Transport auf dem MFD-Netz baut
            //     Mittelbänke/Fäden auf den großen Läufen (Verflechtung).
            if cfg.braidingEnabled { braidPass(dt: dt) }
            // 2) Droplet-Erosion legt die feine dendritische Textur (nickmcd-Look) hinein.
            // Tropfen ∝ Zeit × Fläche (Dichte kalibriert auf n = 640).
            let density = Double(n * n) / (640.0 * 640.0)
            let drops = max(1, Int(dt * cfg.hydraulicPerYear * density))
            let dropSeed = seed &+ stepCount &* 2_654_435_761
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: dropSeed, floor: cfg.floor, p: cfg.hydraulic)
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
