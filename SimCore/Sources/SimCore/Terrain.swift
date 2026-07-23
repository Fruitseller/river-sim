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
    public private(set) var area: [Double]   // Einzugsgebiet (Zellflächen)
    private var order: [Int32]               // Pop-Reihenfolge (aufsteigende Füllhöhe)
    private var floodParent: [Int32]

    private var heap: MinHeap
    private var visited: [Bool]
    private var scratch: [Double] // Arbeitspuffer für die Diffusion
    private var noise: SimplexNoise

    public private(set) var years: Double = 0
    private var seed: UInt32

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
        order = .init(repeating: 0, count: c)
        floodParent = .init(repeating: -1, count: c)
        visited = .init(repeating: false, count: c)
        scratch = .init(repeating: 0, count: c)
        heap = MinHeap(capacity: c)
        noise = SimplexNoise(seed: seed)
        generate(seed: seed)
    }

    @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { j * n + i }

    // MARK: - Terrain-Generierung

    public func generate(seed: UInt32) {
        self.seed = seed
        self.years = 0
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
                let raw = uNoise.value(Double(i) * uFreq + uox, Double(j) * uFreq + uoy)
                upliftBase[idx(i, j)] = raw * 0.7 + 0.12
            }
        }

        // Grundrelief: fBm mit Insel-Falloff → Rand fällt unter den Meeresspiegel,
        // damit die Landschaft natürlich zum Rand entwässert.
        let bf = cfg.baseFreq / Double(n)
        let cx = Double(n - 1) / 2
        for j in 0..<n {
            for i in 0..<n {
                let v01 = noise.fbm01(Double(i) * bf, Double(j) * bf, octaves: cfg.baseOctaves)
                let d = (Double(i) - cx).magnitudeHypot(Double(j) - cx) / cx
                let t = min(max((d - 0.6) / 0.45, 0), 1)
                let falloff = 1 - t * t * (3 - 2 * t) // smoothstep
                h[idx(i, j)] = pow(v01, 1.4) * 0.85 * falloff
            }
        }
        initLayers()
        computeFlow()
        // Vegetation im eingeschwungenen Zustand starten.
        updateVegetation(years: 10000)
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
                if v > cfg.sea + 0.005 && v < 0.58 && hf[k] - h[k] <= 0.015 {
                    let slope = (abs(h[k + 1] - h[k - 1]) + abs(h[k + n] - h[k - n])) * 0.25
                    let slopeOk = max(0, 1 - slope * 40)
                    let wet = min(1, rain[k] * 1.3)
                    let altOk = v < 0.45 ? 1 : max(0, 1 - (v - 0.45) / 0.13)
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

    // MARK: - Hangdiffusion (linear)

    /// Lineare Diffusion dh/dt = D·∇²h — glatte, natürliche Hänge (konkav/konvex)
    /// statt der planaren Facetten/Terrassen der Schwellen-Talus-Methode.
    /// kappa fix bei 0.15 (< 0.25 → explizit stabil), mehrmals pro Sim-Schritt.
    private func diffusionPass() {
        let kappa = 0.03 // schwach: Fluss-Einschneidung + Hebung sollen Relief halten
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

    // MARK: - Zeitschritt

    /// Simuliert `dtYears` Jahre. `dtYears` darf groß sein (Stream-Power ist
    /// implizit stabil); die Hangprozesse werden intern anteilig getaktet.
    public func step(dtYears dt: Double) {
        applyUplift(dt: dt)
        computeFlow()
        streamPower(dt: dt)
        fillLakes(dt: dt)
        // Hangprozesse ~ 1 Pass / 100 Jahre (wie im Prototyp kalibriert).
        let passes = max(1, Int((dt / 100).rounded()))
        for _ in 0..<passes {
            diffusionPass()
            wavePass()
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
