import Foundation

/// Lagrange-Zentrumslinien für die Mäander-Migration. Anders als die D8-
/// Entwässerung (Euler-Grid) ist ein Fluss hier eine *persistente* Polylinie mit
/// Gedächtnis: sie wandert über die Zeit (Prallhang erodiert → Außenkurve
/// verschiebt sich), schnürt Schlingen ab (Cutoff) und hinterlässt Altarme.
///
/// Dieser Kern ist bewusst grid-frei und deterministisch: er operiert nur auf
/// Knoten-Koordinaten (kontinuierliche Grid-Koords, x = Spalte i, z = Zeile j).
/// Die Rückkopplung ins Höhenfeld (Bett-Carve, Ufer-Verschiebung) macht separat
/// `Terrain.meanderStamp` — hier passiert noch nichts am Terrain.

public struct MeanderNode: Equatable, Sendable {
    public var x: Double // Spalte i (kontinuierlich)
    public var z: Double // Zeile j (kontinuierlich)
    public init(x: Double, z: Double) { self.x = x; self.z = z }
}

/// Ein durchgehender Flusslauf von der Quelle bis zur Mündung/zum See.
public struct RiverChannel: Sendable {
    public var nodes: [MeanderNode]
    public var discharge: [Double] // pro Knoten, in Zell-Flächen-Einheiten (∝ Abfluss)

    public init(nodes: [MeanderNode], discharge: [Double]) {
        precondition(nodes.count == discharge.count)
        self.nodes = nodes
        self.discharge = discharge
    }

    /// Lauflänge (Summe der Segmentlängen) in Zellen.
    public var length: Double {
        guard nodes.count > 1 else { return 0 }
        var s = 0.0
        for i in 1..<nodes.count { s += dist(nodes[i - 1], nodes[i]) }
        return s
    }

    /// Sinuosität = Lauflänge / Luftlinie (Quelle→Mündung). 1 = schnurgerade.
    public var sinuosity: Double {
        guard let a = nodes.first, let b = nodes.last else { return 1 }
        let straight = dist(a, b)
        return straight > 1e-9 ? length / straight : 1
    }
}

public final class MeanderState {
    public var channels: [RiverChannel] = []
    /// Abgeschnürte Schleifen (river-history). Alter in Jahren pro Altarm.
    public var oxbows: [[MeanderNode]] = []
    public var oxbowAge: [Double] = []

    // Wiederverwendbare Puffer des räumlichen Cutoff-Index (Produktion,
    // meanderSpatialCutoffIndex): flaches Bin-Gitter mit Linked-List statt
    // Dictionary-of-Arrays — das Dictionary allokierte je Kanal & Schritt und
    // war mit ~5% des Sim-Steps (n=832) der Mäander-Hotspot. `binHead` wird nur
    // an den tatsächlich belegten Zellen (binTouched) zurückgesetzt.
    private var binHead: [Int32] = []
    private var binNext: [Int32] = []
    private var binTouched: [Int32] = []
    private var binW = 0

    public init() {}

    /// Entfernt verlandete Altarme (Alter über `maxAge`) aus der river-history.
    public func pruneOxbows(maxAge: Double) {
        var no: [[MeanderNode]] = [], na: [Double] = []
        for i in oxbows.indices where oxbowAge[i] <= maxAge {
            no.append(oxbows[i]); na.append(oxbowAge[i])
        }
        oxbows = no; oxbowAge = na
    }

    // MARK: - Migrations-Schritt

    /// Ein Migrations-Schritt über `dt` Jahre für alle Läufe:
    /// laterale Verschiebung ∝ Krümmung × Abfluss, dann Glättung, Resample auf
    /// uniformen Knotenabstand und Cutoff-Erkennung. `mobility` gated die
    /// Aktivität (0 = fixiert, z. B. steile Oberläufe; 1 = voll mobil, Flachland);
    /// im entkoppelten M1-Kern ist alles voll mobil.
    /// `heightAt` liefert die Geländehöhe an einer Knotenposition (für das
    /// Flachland-Gate über die *Längsneigung* entlang des Laufs — nicht die
    /// Querneigung, die an eingetieften Kanälen immer steil ist). Default 0 →
    /// überall voll mobil (entkoppelte Kernel-Tests).
    public func migrate(dt: Double, config: SimConfig,
                        heightAt: (MeanderNode) -> Double = { _ in 0 }) {
        let spacing = config.meanderNodeSpacing
        for age in oxbowAge.indices { oxbowAge[age] += dt }
        for ci in channels.indices {
            var ch = channels[ci]
            // Sinuositäts-Deckel: über der Schwelle migriert der Lauf NICHT weiter
            // (sonst tangeln einzelne Läufe zu Knäueln, Sinu → 7..26). Glättung und
            // Cutoff laufen weiter und holen ihn wieder unter die Schwelle → gedeckelt.
            if ch.sinuosity <= config.meanderMaxSinuosity {
                lateralStep(&ch, dt: dt, config: config, heightAt: heightAt)
            }
            smooth(&ch.nodes, factor: config.meanderSmooth)
            applyCutoffs(&ch, config: config)
            ch = resample(ch, spacing: spacing) // Splice-Knick der Cutoffs glätten
            channels[ci] = ch
        }
    }

    /// Verschiebt jeden inneren Knoten lateral ∝ (signierte Krümmung × Abfluss).
    /// Positive Krümmung (Linksbogen) + linke Normale → weiter nach links: die
    /// bestehende Schlinge verstärkt sich (Howard–Knutson, lokale Variante).
    private func lateralStep(_ ch: inout RiverChannel, dt: Double, config: SimConfig,
                             heightAt: (MeanderNode) -> Double) {
        let nodes = ch.nodes
        let count = nodes.count
        guard count >= 3 else { return }
        let k = config.meanderMigration
        let flat = config.meanderFlatSlope
        let cs = config.cellSize
        let maxStep = 0.5 * config.meanderNodeSpacing // CFL: kein Knoten springt >½ Abstand

        // Pass 1: signierte Krümmung, linke Normale, Mobilität, Segmentlänge je Knoten.
        var curv = [Double](repeating: 0, count: count)
        var nlx = [Double](repeating: 0, count: count)
        var nlz = [Double](repeating: 0, count: count)
        var mob = [Double](repeating: 0, count: count)
        var seg = [Double](repeating: config.meanderNodeSpacing, count: count)
        for i in 1..<(count - 1) {
            let a = nodes[i - 1], b = nodes[i], c = nodes[i + 1]
            let v1x = b.x - a.x, v1z = b.z - a.z
            let v2x = c.x - b.x, v2z = c.z - b.z
            let l1 = (v1x * v1x + v1z * v1z).squareRoot()
            let l2 = (v2x * v2x + v2z * v2z).squareRoot()
            let ds = 0.5 * (l1 + l2)
            if ds < 1e-9 { continue }
            seg[i] = ds
            let cross = v1x * v2z - v1z * v2x
            let dot = v1x * v2x + v1z * v2z
            curv[i] = atan2(cross, dot) / ds
            let tx = c.x - a.x, tz = c.z - a.z
            let tl = (tx * tx + tz * tz).squareRoot()
            if tl < 1e-9 { continue }
            nlx[i] = -tz / tl; nlz[i] = tx / tl // linke Normale der Sehne a→c
            let arc = (l1 + l2) * cs               // Flachland-Gate über die Längsneigung
            let longSlope = arc > 1e-9 ? abs(heightAt(a) - heightAt(c)) / arc : 0
            mob[i] = max(0, min(1, 1 - longSlope / flat))
        }

        // Pass 2: upstream-gewichtete Krümmung (Ikeda–Parker–Sawai). Die Bank­erosion
        // hängt von der stromauf integrierten Krümmung ab (das near-bank-Geschwindig­
        // keitsfeld lagt) → die Erosionsspitze verschiebt sich stromab, Schlingen
        // werden asymmetrisch (downstream-geskewt) statt symmetrisch. EMA über
        // steigendes i (= stromab), integriert also j<i (= stromauf).
        let beta = config.meanderSkew
        let lam = max(1e-6, config.meanderSkewLength)
        var eff = curv
        if beta > 0 {
            var ema = 0.0
            var sumC = 0.0, sumE = 0.0
            for i in 0..<count {
                eff[i] = (1 - beta) * curv[i] + beta * ema
                let w = exp(-seg[i] / lam)
                ema = ema * w + curv[i] * (1 - w)
                sumC += abs(curv[i]); sumE += abs(eff[i])
            }
            // Auf gleiche Gesamt-Stärke normieren: die EMA ist ein Tiefpass und
            // würde die Amplitude (und damit die Mäander-Rate) sonst dämpfen.
            // Der Skew verschiebt so nur die Phase (Erosionsspitze stromab).
            let sc = sumE > 1e-9 ? sumC / sumE : 1
            for i in 0..<count { eff[i] *= sc }
        }

        // Pass 3: Knoten entlang lokaler Normale verschieben (Betrag aus eff).
        var out = nodes
        for i in 1..<(count - 1) {
            // −eff: zum Außenufer (weg vom Krümmungszentrum) → Schlinge verstärkt sich
            var m = -k * ch.discharge[i] * eff[i] * dt * mob[i]
            m = max(-maxStep, min(maxStep, m)) // Displacement-Clamp gegen Verheddern
            out[i] = MeanderNode(x: nodes[i].x + m * nlx[i], z: nodes[i].z + m * nlz[i])
        }
        ch.nodes = out
    }

    /// Milde Laplace-Glättung (Endpunkte fest), hält den Lauf gegen die D8-
    /// Treppe und Zacken glatt, ohne die Amplifikation zu ersticken.
    private func smooth(_ nodes: inout [MeanderNode], factor: Double) {
        guard factor > 0, nodes.count >= 3 else { return }
        let src = nodes
        for i in 1..<(src.count - 1) {
            let lx = (src[i - 1].x + 2 * src[i].x + src[i + 1].x) * 0.25
            let lz = (src[i - 1].z + 2 * src[i].z + src[i + 1].z) * 0.25
            nodes[i].x = src[i].x + (lx - src[i].x) * factor
            nodes[i].z = src[i].z + (lz - src[i].z) * factor
        }
    }

    // MARK: - Cutoff (Abschnürung → Altarm)

    /// Schnürt Schlingen ab, deren Hals enger als `neckDist` ist, sofern die
    /// Schleife dazwischen entlang des Laufs deutlich länger ist (echter Hals,
    /// kein Nachbar). Die herausgeschnittene Schleife wird ein Altarm.
    private func applyCutoffs(_ ch: inout RiverChannel, config: SimConfig) {
        let neck = config.meanderNeckDist
        guard neck > 0 else { return }
        let spacing = config.meanderNodeSpacing
        // Mindest-Index-Abstand: die Schleife muss ein Vielfaches des Halses lang
        // sein, sonst sind es bloß Nachbarknoten.
        let minSep = max(4, Int((neck / max(spacing, 1e-6)) * 3) + 2)
        var guardN = 0
        while guardN < 64 {
            guardN += 1
            var cut: (Int, Int)? = nil
            if config.meanderSpatialCutoffIndex {
                // Nur Knoten aus den eigenen/nebenliegenden Zellen können einen
                // Hals bilden. Das erhält das früheste (i, j) der Vollsuche.
                // Bin-Koordinaten werden ins Gitter GEKLEMMT (Knoten können während
                // der Migration kurz aus der Welt driften): Klemmen ist monoton →
                // Paare mit dist < neck bleiben in benachbarten Bins, und der exakte
                // dist-Filter macht das Ergebnis identisch zur Dictionary-Variante.
                let gw = max(1, Int(Double(config.n) / neck) + 2)
                if binW != gw { binW = gw; binHead = [Int32](repeating: -1, count: gw * gw) }
                let count = ch.nodes.count
                if binNext.count < count { binNext = [Int32](repeating: -1, count: count) }
                for c in binTouched { binHead[Int(c)] = -1 }
                binTouched.removeAll(keepingCapacity: true)
                @inline(__always) func binX(_ v: Double) -> Int {
                    min(max(Int((v / neck).rounded(.down)), 0), gw - 1)
                }
                for i in 0..<count {
                    let b = binX(ch.nodes[i].z) * gw + binX(ch.nodes[i].x)
                    if binHead[b] < 0 { binTouched.append(Int32(b)) }
                    binNext[i] = binHead[b]
                    binHead[b] = Int32(i)
                }
                outer: for i in 0..<count {
                    let node = ch.nodes[i]
                    let x = binX(node.x), z = binX(node.z)
                    var bestJ = Int.max
                    for bz in max(0, z - 1)...min(gw - 1, z + 1) {
                        for bx in max(0, x - 1)...min(gw - 1, x + 1) {
                            var jj = binHead[bz * gw + bx]
                            while jj >= 0 {
                                let j = Int(jj)
                                jj = binNext[j]
                                if j >= i + minSep && j < bestJ && dist(node, ch.nodes[j]) < neck {
                                    bestJ = j
                                }
                            }
                        }
                    }
                    if bestJ < Int.max { cut = (i, bestJ); break outer }
                }
            } else {
                outer: for i in 0..<ch.nodes.count {
                    var j = i + minSep
                    while j < ch.nodes.count {
                        if dist(ch.nodes[i], ch.nodes[j]) < neck { cut = (i, j); break outer }
                        j += 1
                    }
                }
            }
            guard let (i, j) = cut else { break }
            oxbows.append(Array(ch.nodes[i...j]))
            oxbowAge.append(0)
            var newNodes = Array(ch.nodes[0...i])
            newNodes.append(contentsOf: ch.nodes[j...])
            var newDis = Array(ch.discharge[0...i])
            newDis.append(contentsOf: ch.discharge[j...])
            ch = RiverChannel(nodes: newNodes, discharge: newDis)
        }
    }

    // MARK: - Resample auf uniformen Knotenabstand

    /// Verteilt die Knoten auf ~uniformen Abstand `spacing` (Knoten stauen sich
    /// sonst in engen Bögen), Endpunkte bleiben exakt erhalten. Abfluss wird
    /// entlang der Bogenlänge mitinterpoliert.
    private func resample(_ ch: RiverChannel, spacing: Double) -> RiverChannel {
        let nodes = ch.nodes
        guard nodes.count >= 2, spacing > 0 else { return ch }
        var cum = [Double](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        let total = cum[nodes.count - 1]
        if total < spacing { // zu kurz → nur Endpunkte
            return RiverChannel(nodes: [nodes[0], nodes[nodes.count - 1]],
                                discharge: [ch.discharge[0], ch.discharge[nodes.count - 1]])
        }
        let count = max(2, Int((total / spacing).rounded()) + 1)
        var outN = [MeanderNode](); outN.reserveCapacity(count)
        var outD = [Double](); outD.reserveCapacity(count)
        var seg = 0
        for kk in 0..<count {
            let target = total * Double(kk) / Double(count - 1)
            while seg < nodes.count - 2 && cum[seg + 1] < target { seg += 1 }
            let segLen = cum[seg + 1] - cum[seg]
            let t = segLen > 1e-9 ? (target - cum[seg]) / segLen : 0
            outN.append(MeanderNode(x: nodes[seg].x + (nodes[seg + 1].x - nodes[seg].x) * t,
                                    z: nodes[seg].z + (nodes[seg + 1].z - nodes[seg].z) * t))
            outD.append(ch.discharge[seg] + (ch.discharge[seg + 1] - ch.discharge[seg]) * t)
        }
        return RiverChannel(nodes: outN, discharge: outD)
    }

    // MARK: - Initialisierung aus der D8-Entwässerung

    /// Tract die großen Läufe aus der Entwässerung (Quelle = große Zelle ohne
    /// großen Zufluss-Nachbarn; dann der Empfänger-Kette bis Meer/See folgen) und
    /// resampled sie auf `spacing`. Teilt die Logik mit `SimNode.buildRivers`.
    public static func traceChannels(config: SimConfig, h: [Double], hf: [Double],
                                     area: [Double], receiver: [Int32]) -> [RiverChannel] {
        let n = config.n
        let sea = config.sea
        let cellArea = config.cellSize * config.cellSize
        let minCells = config.meanderMinCells
        let lakeEps = 0.035

        var isBig = [Bool](repeating: false, count: n * n)
        for k in 0..<(n * n) where hf[k] > sea && area[k] / cellArea >= minCells { isBig[k] = true }

        func isSource(_ k: Int) -> Bool {
            if !isBig[k] { return false }
            let i = k % n, j = k / n
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    if isBig[nb] && Int(receiver[nb]) == k { return false }
                }
            }
            return true
        }

        let state = MeanderState() // nur für resample() wiederverwendet
        var drawn = [Bool](repeating: false, count: n * n)
        var result: [RiverChannel] = []
        for s in 0..<(n * n) where isSource(s) {
            var cells: [Int] = []
            var c = s, guardN = 0
            while guardN < n * n {
                guardN += 1
                cells.append(c)
                if drawn[c] && cells.count > 1 { break }
                drawn[c] = true
                let r = receiver[c]
                if r < 0 { break }
                let ri = Int(r)
                if hf[ri] <= sea || hf[ri] - h[ri] > lakeEps { break }
                c = ri
            }
            if cells.count < 3 { continue }
            var nodes = [MeanderNode](); nodes.reserveCapacity(cells.count)
            var dis = [Double](); dis.reserveCapacity(cells.count)
            for k in cells {
                nodes.append(MeanderNode(x: Double(k % n), z: Double(k / n)))
                dis.append(area[k] / cellArea)
            }
            result.append(state.resample(RiverChannel(nodes: nodes, discharge: dis),
                                          spacing: config.meanderNodeSpacing))
        }
        return result
    }
}

@inline(__always) func dist(_ a: MeanderNode, _ b: MeanderNode) -> Double {
    let dx = a.x - b.x, dz = a.z - b.z
    return (dx * dx + dz * dz).squareRoot()
}
