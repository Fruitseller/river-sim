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

    /// Frischt `discharge` je Knoten aus einem Feld-Sampler auf. Die Schleife
    /// steht hier statt beim Aufrufer, damit sie auf den EIGENEN (eindeutig
    /// referenzierten) Arrays läuft — über `terrain.meander.channels[ci]…`
    /// kostete jeder Knoten COW- und Exklusivitätsprüfungen (Issue #43).
    public mutating func refreshDischarge(_ sample: (Double, Double) -> Double) {
        for i in nodes.indices { discharge[i] = sample(nodes[i].x, nodes[i].z) }
    }

    /// Hält alle Knoten im Gitter [0, `maxCoord`] (Sicherheits-Clamp).
    /// Konstante zuerst (`min(maxCoord, max(0, …))`), damit ungültige
    /// Koordinaten (NaN) sicher zu 0 gefaltet werden.
    public mutating func clampToWorld(maxCoord: Double) {
        guard maxCoord >= 0, maxCoord.isFinite else { return }
        for i in nodes.indices {
            nodes[i].x = min(maxCoord, max(0, nodes[i].x))
            nodes[i].z = min(maxCoord, max(0, nodes[i].z))
        }
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
    /// Zähler der Cutoffs seit `generate`/`restore` (Diagnose für Issue #174,
    /// Abnahmepunkt 15) — kein Sim-Zustand: kein Pass liest sie.
    public private(set) var neckCutoffs = 0
    public private(set) var chuteCutoffs = 0
    /// Zähler der Kopplung an die Entwässerung (Issue #187), ebenfalls nur
    /// Diagnose: Avulsionen (verlassenes Gerinne eines wandernden Laufs) und
    /// D8-Abschnitte, die ohne alte Linie neu getrasst wurden (je Schritt).
    public internal(set) var avulsions = 0
    public internal(set) var retraced = 0
    /// Knoten wandernder Größe (Abfluss ab `meanderBeltMinCells`), die die
    /// Kopplung übernommen bzw. durch D8-Zellen ersetzt hat (kumuliert).
    public internal(set) var coupledKept = 0
    public internal(set) var coupledInserted = 0
    /// Davon: vor der ersten Strecke, zwischen zwei Strecken desselben alten
    /// Laufs, zwischen Strecken verschiedener Läufe, nach der letzten (Diagnose).
    public internal(set) var insertedByPlace = [0, 0, 0, 0]

    // Wiederverwendbare Puffer des räumlichen Cutoff-Index (Produktion,
    // meanderSpatialCutoffIndex): flaches Bin-Gitter mit Linked-List statt
    // Dictionary-of-Arrays — das Dictionary allokierte je Kanal & Schritt und
    // war mit ~5% des Sim-Steps (n=832) der Mäander-Hotspot. `binHead` wird nur
    // an den tatsächlich belegten Zellen (binTouched) zurückgesetzt.
    private var binHead: [Int32] = []
    private var binNext: [Int32] = []
    private var binTouched: [Int32] = []
    private var binW = 0
    // Dasselbe für `applyBeltCutoffs` (Gürtel).
    private var cutBinHead: [Int32] = []
    private var cutBinNext: [Int32] = []
    private var cutBinTouched: [Int32] = []

    public init() {}

    /// Entfernt verlandete Altarme (Alter über `maxAge`) aus der river-history.
    public func pruneOxbows(maxAge: Double) {
        var no: [[MeanderNode]] = [], na: [Double] = []
        let count = min(oxbows.count, oxbowAge.count)
        for i in 0..<count where oxbowAge[i] <= maxAge {
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
    /// `riparianAt` liefert das mittlere Auwald-veg (0..1) im Ufer-Streifen um
    /// einen Knoten (Terrain.riparianVegAt): bewachsene Ufer sind kohäsiv und
    /// migrieren langsamer — Faktor (1 − meanderCohesion·riparianAt). Default 0
    /// → keine Kohäsion (entkoppelte Kernel-Tests bleiben unverändert).
    public func migrate(dt: Double, config: SimConfig,
                        heightAt: (MeanderNode) -> Double = { _ in 0 },
                        riparianAt: (MeanderNode) -> Double = { _ in 0 }) {
        let spacing = config.meanderNodeSpacing
        for age in oxbowAge.indices { oxbowAge[age] += dt }
        for ci in channels.indices {
            var ch = channels[ci]
            // Sinuositäts-Deckel: über der Schwelle migriert der Lauf NICHT weiter
            // (sonst tangeln einzelne Läufe zu Knäueln, Sinu → 7..26). Glättung und
            // Cutoff laufen weiter und holen ihn wieder unter die Schwelle → gedeckelt.
            if ch.sinuosity <= config.meanderMaxSinuosity {
                lateralStep(&ch, dt: dt, config: config, heightAt: heightAt,
                            riparianAt: riparianAt)
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
                             heightAt: (MeanderNode) -> Double,
                             riparianAt: (MeanderNode) -> Double = { _ in 0 }) {
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
        let cohesion = config.meanderCohesion
        var out = nodes
        for i in 1..<(count - 1) {
            // −eff: zum Außenufer (weg vom Krümmungszentrum) → Schlinge verstärkt sich.
            // Ufer-Kohäsion: Auwald-bewachsene Ufer (riparianAt) bremsen die
            // Migration — Wurzelwerk hält den Prallhang (Stufe 2).
            let coh = cohesion > 0 ? max(0, min(1, riparianAt(nodes[i]))) : 0
            var m = -k * ch.discharge[i] * eff[i] * dt * mob[i] * (1 - cohesion * coh)
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
        guard neck > 0, neck.isFinite else { return }
        let spacing = config.meanderNodeSpacing
        guard spacing.isFinite else { return }
        // Mindest-Index-Abstand: die Schleife muss ein Vielfaches des Halses lang
        // sein, sonst sind es bloß Nachbarknoten.
        // Verhältnis vor der Konvertierung begrenzen, um Int-Überlauf bei extrem
        // kleinem meanderNodeSpacing defensiv abzufangen.
        let rawSep = (neck / max(1e-6, spacing)) * 3
        let sepCount = (rawSep.isFinite && rawSep >= 0) ? Int(min(Double(ch.nodes.count + 2), rawSep)) : 0
        let minSep = max(4, sepCount + 2)
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
                // gw vor der Konversion begrenzen, um Int-Überlauf bei extrem
                // kleinem meanderNeckDist (z. B. 1e-300) und Speicher-Explosion
                // im flachen Bin-Gitter (gw * gw) defensiv zu verhindern.
                let rawGw = Double(config.n) / neck
                let gw = (rawGw.isFinite && rawGw >= 0) ? max(1, Int(min(4096.0, rawGw)) + 2) : 1
                if binW != gw { binW = gw; binHead = [Int32](repeating: -1, count: gw * gw) }
                let count = ch.nodes.count
                if binNext.count < count { binNext = [Int32](repeating: -1, count: count) }
                for c in binTouched { binHead[Int(c)] = -1 }
                binTouched.removeAll(keepingCapacity: true)
                @inline(__always) func binX(_ v: Double) -> Int {
                    guard v.isFinite else { return 0 }
                    let cell = (v / neck).rounded(.down)
                    guard cell >= 0 else { return 0 }
                    guard cell < Double(gw) else { return gw - 1 }
                    return Int(cell)
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
        guard nodes.count >= 2, spacing > 0, spacing.isFinite else { return ch }
        var cum = [Double](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        let total = cum[nodes.count - 1]
        guard total.isFinite else { return ch }
        if total < spacing { // zu kurz → nur Endpunkte
            return RiverChannel(nodes: [nodes[0], nodes[nodes.count - 1]],
                                discharge: [ch.discharge[0], ch.discharge[nodes.count - 1]])
        }
        // Schrittzahl vor der Konvertierung deckeln, um Int(inf) bzw. Überlauf bei
        // extrem kleinem spacing (z. B. meanderNodeSpacing = 1e-320) abzufangen.
        let rawSteps = (total / spacing).rounded()
        guard rawSteps.isFinite, rawSteps >= 0 else { return ch }
        let maxSteps = 65_536
        let steps = Int(min(Double(maxSteps), rawSteps))
        let count = max(2, steps + 1)
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
    /// resampled sie auf `spacing`. EINZIGE Trasse im Projekt: die Render-Seite
    /// (`SimRender.RiverRibbonRenderer`) baut ihre Bänder aus den fertigen
    /// `terrain.meander.channels` und trasst nicht selbst — der frühere Zwilling
    /// `SimNode.buildRivers` ist mit f3556c8 entfallen.
    ///
    /// Mismatch der Pufferlängen, leere Terrains sowie Empfänger-Indizes außerhalb
    /// des Gitters (`r < 0 || r >= n*n`) werden defensiv abgefangen.
    public static func traceChannels(config: SimConfig, h: [Double], hf: [Double],
                                     area: [Double], receiver: [Int32]) -> [RiverChannel] {
        let n = config.n
        guard n > 0 else { return [] }
        let (count, overflow) = n.multipliedReportingOverflow(by: n)
        guard !overflow,
              h.count == count, hf.count == count,
              area.count == count, receiver.count == count else { return [] }
        let cellArea = config.cellSize * config.cellSize
        let minCells = config.meanderMinCells
        guard cellArea > 0, cellArea.isFinite,
              minCells > 0, minCells.isFinite else { return [] }
        let sea = config.sea
        let lakeEps = traceLakeDepth

        var isBig = [Bool](repeating: false, count: count)
        for k in 0..<count where hf[k] > sea && area[k] / cellArea >= minCells { isBig[k] = true }
        if config.meanderBelt && config.meanderBeltCoupling {
            return traceHorton(config: config, h: h, hf: hf, area: area, receiver: receiver)
        }

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
        var drawn = [Bool](repeating: false, count: count)
        var result: [RiverChannel] = []
        var sources = (0..<count).filter(isSource)
        if config.meanderBelt {
            // Hauptstamm zuerst (Hack): die Quelle mit dem längsten Fließweg zieht
            // den Stamm bis zur Mündung, Zubringer enden an ihm. In Index-
            // Reihenfolge besaß die zuerst gezogene Quelle den Unterlauf — oft eine
            // kurze nahe der Küste, und der Stamm zerfiel gemessen in Stummel
            // (größter Lauf: 30 Knoten). Feste Enden und die Rand-Ausblendung
            // lassen auf Stummeln keinen Bogen wachsen.
            var pathLen = [Int](repeating: 0, count: count)
            for s0 in sources {
                var c = s0, steps = 0
                while steps < count {
                    steps += 1
                    let r = Int(receiver[c])
                    if r < 0 || r >= count || hf[r] <= sea || hf[r] - h[r] > lakeEps { break }
                    c = r
                }
                pathLen[s0] = steps
            }
            sources.sort { pathLen[$0] != pathLen[$1] ? pathLen[$0] > pathLen[$1] : $0 < $1 }
        }
        for s in sources {
            var cells: [Int] = []
            var c = s, guardN = 0
            while guardN < count {
                guardN += 1
                cells.append(c)
                if drawn[c] && cells.count > 1 { break }
                drawn[c] = true
                let r = Int(receiver[c])
                if r < 0 || r >= count { break }
                if hf[r] <= sea || hf[r] - h[r] > lakeEps { break }
                c = r
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

// MARK: - Kopplung an die Entwässerung (Issue #187)

extension MeanderState {
    /// Wassersäule, ab der eine geflutete Zelle als See zählt: eine Trasse endet
    /// davor (`traceChannels`, `Terrain.drainageSegments`).
    static let traceLakeDepth = 0.035

    /// Trasse nach dem Hack-Prinzip (Issue #187): an jedem Zusammenfluss läuft
    /// der Lauf mit dem GRÖSSEREN Einzugsgebiet weiter (Gleichstand: kleinerer
    /// Index), der kleinere endet in der Zusammenfluss-Zelle — dieselben
    /// Abschnitte (`Terrain.drainageSegments`), aus denen die Kopplung die Läufe
    /// jeden Schritt neu zusammensetzt. Bis #187 zog `traceChannels` den
    /// längsten Fließweg zuerst bis zur Mündung; an jedem Zusammenfluss mit
    /// einem größeren Fluss besaß damit der KLEINERE den Unterlauf.
    static func traceHorton(config: SimConfig, h: [Double], hf: [Double], area: [Double],
                            receiver: [Int32]) -> [RiverChannel] {
        let n = config.n, cellArea = config.cellSize * config.cellSize
        let segs = h.withUnsafeBufferPointer { hb in
            hf.withUnsafeBufferPointer { hfb in
            area.withUnsafeBufferPointer { ab in
            receiver.withUnsafeBufferPointer { rb in
                Terrain.drainageSegments(config: config, h: hb.baseAddress!, hf: hfb.baseAddress!,
                                         area: ab.baseAddress!, receiver: rb.baseAddress!)
            }}}
        }
        let state = MeanderState() // nur für resample() wiederverwendet
        return segs.map { seg in
            let nodes = seg.cells.map { MeanderNode(x: Double(Int($0) % n), z: Double(Int($0) / n)) }
            var dis = seg.cells.map { area[Int($0)] / cellArea }
            // Die Zusammenfluss-Zelle gehört dem größeren Fluss.
            if seg.endsAtConfluence { dis[dis.count - 1] = dis[dis.count - 2] }
            return state.resample(RiverChannel(nodes: nodes, discharge: dis), spacing: config.meanderNodeSpacing)
        }
    }

    /// Lauf neu auf `meanderNodeSpacing` abtasten (Zugang für `Terrain`).
    func resampled(_ ch: RiverChannel, config: SimConfig) -> RiverChannel {
        resample(ch, spacing: config.meanderNodeSpacing)
    }

    /// Ein verlassenes Gerinne wird ein Altarm (`Terrain.plugOxbows` verkorkt
    /// seine Enden, `fillOxbows` verlandet es) — wie nach einem Cutoff.
    func abandon(_ nodes: [MeanderNode], age: Double) {
        oxbows.append(nodes)
        oxbowAge.append(age)
    }
}

// MARK: - Mäandergürtel (Issue #174, Paket B)

/// Geometrie eines Laufs auf Breiten-Skala, je Knoten.
struct BeltGeometry {
    /// Kanalbreite (Zellen).
    var width: [Double]
    /// Signierte Krümmung (1/Zellen) über ±k Knoten, k ≈ halbe Kanalbreite:
    /// Knicke unterhalb der Kanalbreite sind kein Bogen und treiben nichts.
    var curv: [Double]
    /// Linke Normale der Sehne über dieselben Knoten.
    var nx: [Double]
    var nz: [Double]
    /// Mobilität 0…1 aus der Längsneigung (Flachland-Gate, `meanderFlatSlope`).
    var mob: [Double]
    /// Kumulierte Bogenlänge entlang der Knoten (Zellen), wiederverwendet in `beltRatesAndErodibility`.
    var cum: [Double] = []
}

extension MeanderState {
    /// Wandert dieser Lauf überhaupt? Erst ab `meanderBeltMinCells` Abfluss; der
    /// Abfluss ist entlang des Laufs monoton, der letzte INNENKNOTEN reicht
    /// also. Nur diese Läufe (einige Dutzend von ~700) laufen durch die
    /// Teilschritte — vorher kostete der Gürtel 99 ms je Schritt.
    /// Bis #187 entschied der Endknoten: er sitzt bei einem Zubringer auf der
    /// Mündungszelle und trug über das 3×3-Maximum den Abfluss des Vorfluters,
    /// gemessen zählten 208 von 718 Läufen als wandernd, nur 38–44 davon mit
    /// einem Innenknoten über der Schwelle (ohne Kopplung bleibt das so, für
    /// den A/B-Vergleich).
    @inline(__always) static func migrates(_ ch: RiverChannel, _ config: SimConfig) -> Bool {
        guard config.meanderBeltCoupling, ch.discharge.count >= 2 else {
            return (ch.discharge.last ?? 0) >= config.meanderBeltMinCells
        }
        return ch.discharge[ch.discharge.count - 2] >= config.meanderBeltMinCells
    }

    /// Kanalbreite (Zellen) aus dem Abfluss — DIESELBE Kurve wie die
    /// Band-Geometrie (`WaterRender.ribbonHalfWidthCells`), damit Bett und Band
    /// gleich breit sind (Issue #174).
    public static func beltWidthCells(discharge: Double, config: SimConfig) -> Double {
        2 * WaterRender.ribbonHalfWidthCells(dischargeCells: discharge,
                                             referenceCells: config.renderMinCells)
    }

    /// Signierte Bogenstärke je Knoten (−1 … +1) für den Render (Issue #174,
    /// Paket C Teil 2): dieselbe Größe `a`, mit der `Terrain.beltStamp` den
    /// Kolk zur Außenkurve schiebt (|Krümmung| · Breite · `meanderBeltPoolGain`,
    /// gedeckelt auf 1), mit dem Vorzeichen der Krümmung (+ = Linksbogen,
    /// Außenseite rechts der Fließrichtung) und mal der Mobilität: wo die Sim
    /// kein asymmetrisches Profil baut (steile Strecke), ist auch keins zu
    /// malen. Liest nur, ändert nichts.
    public static func bendStrength(_ ch: RiverChannel, config: SimConfig,
                                    heightAt: (MeanderNode) -> Double) -> [Double] {
        guard ch.nodes.count >= 3, ch.discharge.count >= ch.nodes.count else {
            return [Double](repeating: 0, count: ch.nodes.count)
        }
        let g = beltGeometry(ch, config: config, heightAt: heightAt)
        let curv = bendCurvature(g, config: config)
        return (0..<ch.nodes.count).map { i in
            let a = curv[i] * g.width[i] * config.meanderBeltPoolGain
            return max(-1, min(1, a)) * g.mob[i]
        }
    }

    /// Bogen-Krümmung für das Querprofil: `g.curv` gemittelt über
    /// ±`meanderBeltProfileWidths` Kanalbreiten (0 = `g.curv` selbst).
    /// `g.curv` (±½ Breite) trägt noch Knicke im Knotenabstand (gemessen
    /// |κ|·b bis 5, Radius unter einer halben Breite); daraus legte der
    /// Stempel Knoten für Knoten abwechselnd gekippte Profile übereinander,
    /// im Mittel ein symmetrisches V. Kolk und Gleithang antworten auf den
    /// BOGEN, nicht auf den Knick. EINE Quelle für Stempel und Render.
    static func bendCurvature(_ g: BeltGeometry, config: SimConfig,
                              activeRange: ClosedRange<Int>? = nil) -> [Double] {
        let c = g.curv.count
        var out = g.curv
        guard c >= 3 else { return out }
        let spc = max(1e-6, config.meanderNodeSpacing)
        let rLo = max(1, activeRange?.lowerBound ?? 1)
        let rHi = min(c - 2, activeRange?.upperBound ?? (c - 2))
        guard rLo <= rHi else { return out }
        for i in rLo...rHi {
            let kb = Int((config.meanderBeltProfileWidths * g.width[i] / spc).rounded())
            guard kb > 0 else { continue }
            let lo = max(1, i - kb), hi = min(c - 2, i + kb)
            var acc = 0.0
            for j in lo...hi { acc += g.curv[j] }
            out[i] = acc / Double(hi - lo + 1)
        }
        return out
    }

    static func beltGeometry(_ ch: RiverChannel, config: SimConfig,
                             minDischarge: Double = 0,
                             heightAt: (MeanderNode) -> Double) -> BeltGeometry {
        let nodes = ch.nodes, c = nodes.count
        var cum = [Double](repeating: 0, count: c)
        for i in 1..<max(1, c) { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        var g = BeltGeometry(width: .init(repeating: 0, count: c), curv: .init(repeating: 0, count: c),
                             nx: .init(repeating: 0, count: c), nz: .init(repeating: 0, count: c),
                             mob: .init(repeating: 0, count: c), cum: cum)
        let sp = max(1e-6, config.meanderNodeSpacing)
        for i in 0..<c {
            let b = beltWidthCells(discharge: ch.discharge[i], config: config)
            g.width[i] = b
            guard i > 0, i < c - 1 else { continue }
            let k = max(1, min(min(i, c - 1 - i), Int((0.5 * b / sp).rounded())))
            let a = nodes[i - k], m = nodes[i], d = nodes[i + k]
            let v1x = m.x - a.x, v1z = m.z - a.z, v2x = d.x - m.x, v2z = d.z - m.z
            let l1 = (v1x * v1x + v1z * v1z).squareRoot(), l2 = (v2x * v2x + v2z * v2z).squareRoot()
            let ds = 0.5 * (l1 + l2)
            guard ds > 1e-9 else { continue }
            g.curv[i] = atan2(v1x * v2z - v1z * v2x, v1x * v2x + v1z * v2z) / ds
            let tx = d.x - a.x, tz = d.z - a.z, tl = (tx * tx + tz * tz).squareRoot()
            guard tl > 1e-9 else { continue }
            g.nx[i] = -tz / tl; g.nz[i] = tx / tl
            if minDischarge > 0 && ch.discharge[i] < minDischarge { continue }
            g.mob[i] = beltMobility(nodes, cum, i: i, width: b, k: k, config: config, heightAt: heightAt)
        }
        return g
    }

    /// Nach einem Stempel bleibt die Linie gleich, nur das Höhenfeld ändert
    /// sich. Krümmung, Normalen, Breiten und Bogenlängen bleiben dafür gültig;
    /// die Mobilität wird aus dem aktuellen Bett vollständig neu gelesen.
    static func updateBeltMobility(_ g: inout BeltGeometry, _ ch: RiverChannel, config: SimConfig,
                                   minDischarge: Double, heightAt: (MeanderNode) -> Double) {
        let nodes = ch.nodes, c = nodes.count
        let sp = max(1e-6, config.meanderNodeSpacing)
        let cum = g.cum
        for i in 1..<max(1, c - 1) {
            g.mob[i] = 0
            guard g.nx[i] != 0 || g.nz[i] != 0 else { continue }
            if minDischarge > 0 && ch.discharge[i] < minDischarge { continue }
            let b = g.width[i]
            let k = max(1, min(min(i, c - 1 - i), Int((0.5 * b / sp).rounded())))
            g.mob[i] = beltMobility(nodes, cum, i: i, width: b, k: k, config: config, heightAt: heightAt)
        }
    }

    @inline(__always)
    private static func beltMobility(_ nodes: [MeanderNode], _ cum: [Double], i: Int,
                                     width b: Double, k: Int, config: SimConfig,
                                     heightAt: (MeanderNode) -> Double) -> Double {
        let c = nodes.count, sp = max(1e-6, config.meanderNodeSpacing)
        let cs = config.cellSize, flat = config.meanderFlatSlope
        let total = cum[c - 1]
        // Über ±k (≈ 3 Zellen) brach jede Stufe im eingeschnittenen Bett den
        // mobilen Abschnitt auf (gemessen 12–45 mobile Knoten am Hauptlauf
        // von Seed 1337). Deshalb ±1,5 Kanalbreiten.
        let ks = max(k, min(min(i, c - 1 - i), Int((1.5 * b / sp).rounded())))
        let arc = (cum[i + ks] - cum[i - ks]) * cs
        let slope = arc > 1e-9 ? abs(heightAt(nodes[i - ks]) - heightAt(nodes[i + ks])) / arc : 0
        // Unter dem Meer wandert nichts; an Quelle und Mündung ausblenden,
        // sonst staut sich der Stromauf-Term am festen Ende zu Spiralen.
        var mob = flat > 0 && heightAt(nodes[i]) > config.sea ? max(0, min(1, 1 - slope / flat)) : 0
        mob *= min(1, min(cum[i], total - cum[i]) / max(1e-6, 3 * b))
        return mob
    }

    /// Verschiebungsrate je Knoten (Zellen/Jahr entlang der linken Normalen)
    /// nach Howard–Knutson: `Ω·C + Γ·∫C stromauf`, Kern-Länge ∝ Breite, Rate
    /// ∝ Breite × (Breite · eff). Mit Mobilität und Talwand-Bremse.
    func beltRates(_ ch: RiverChannel, _ g: BeltGeometry, config: SimConfig,
                   heightAt: (MeanderNode) -> Double) -> [Double] {
        beltRatesAndErodibility(ch, g, config: config, heightAt: heightAt).rate
    }

    /// Rate (Zellen/Jahr) und Ufer-Erodierbarkeit je Knoten (0…1: Mobilität ×
    /// Talwand-Bremse). Die Erodierbarkeit skaliert AUCH den impliziten
    /// Lokalterm in `migrateBeltChannel`: bremste sie nur den Wachstumsterm,
    /// überwog an jeder gebremsten Stelle die Diffusion, und die Linie wurde
    /// gerade statt stehen zu bleiben (gemessen: Rate 1,5 Zellen je 1000
    /// Jahre, Bewegung 0,2, Sinuosität fallend).
    ///
    /// Entfernt mit #187 (beide standen auf 0 und änderten nichts): der Zug zur
    /// tieferen Uferseite (`meanderBeltPull`; mit Stärke 1 hielt er in jedem
    /// V-Tal die Linie gerade, Sinuosität 1,2) und die Ufer-Kohäsion
    /// (`meanderBeltCohesion`; mit 0,5 Sinuosität 1,3 statt 2,0, Bewuchs bremst
    /// im Gürtel über die Ufer-Zerstörung im Stempel). Die Kopplung an die
    /// Entwässerung leistet jetzt `Terrain.coupleBeltToDrainage`.
    func beltRatesAndErodibility(_ ch: RiverChannel, _ g: BeltGeometry, config: SimConfig,
                                 heightAt: (MeanderNode) -> Double, boundOnly: Bool = false) -> (rate: [Double], erod: [Double]) {
        let nodes = ch.nodes, c = nodes.count
        var rate = [Double](repeating: 0, count: c)
        var erod = [Double](repeating: 0, count: c)
        let ga = config.meanderBeltUpstreamWeight
        let kw = config.meanderBeltKernelWidths, e = config.meanderBeltRate
        // Örtliche Sinuosität über ±`meanderBeltSinuosityWidths` Breiten.
        let cum: [Double]
        if g.cum.count == c {
            cum = g.cum
        } else {
            var tmp = [Double](repeating: 0, count: c)
            for i in 1..<c { tmp[i] = tmp[i - 1] + dist(nodes[i - 1], nodes[i]) }
            cum = tmp
        }
        let sp = max(1e-6, config.meanderNodeSpacing)
        let s0 = config.meanderBeltSinuosityStart, s1 = config.meanderBeltSinuosityFull
        // Stromab integrierte Krümmung (Spiegelbild von `ema`, ohne Knoten i).
        let gd = config.meanderBeltDownstreamWeight
        var down = [Double](repeating: 0, count: gd != 0 ? c : 0)
        if gd != 0 {
            var emaD = 0.0
            for i in stride(from: c - 1, through: 0, by: -1) {
                let seg = i < c - 1 ? dist(nodes[i], nodes[i + 1]) : 0
                let w = exp(-seg / max(1e-6, kw * g.width[i]))
                emaD *= w
                down[i] = emaD
                emaD += g.curv[i] * (1 - w)
            }
        }
        var ema = 0.0
        for i in 0..<c {
            let seg = i > 0 ? dist(nodes[i - 1], nodes[i]) : 0
            let w = exp(-seg / max(1e-6, kw * g.width[i]))
            ema *= w                                    // stromauf integriert, ohne Knoten i selbst
            // Nur der Stromauf-Term: der LOKALE Term (Ω < 0, zur Krümmungsmitte)
            // ist eine Diffusion der Linie mit κ = |Ω|·Rate·b² und läuft als
            // implizit stabile Glättung in `migrateBeltChannel` (s. dort).
            let eff = ga * ema + (gd != 0 ? gd * down[i] : 0)
            ema += g.curv[i] * (1 - w)
            guard i > 0, i < c - 1, (boundOnly || g.mob[i] > 0), ch.discharge[i] >= config.meanderBeltMinCells else { continue }
            let b = g.width[i]
            if boundOnly {
                rate[i] = abs(-e * b * (b * eff))
                continue
            }
            let m = max(1, Int((config.meanderBeltSinuosityWidths * b / sp).rounded()))
            let lo = max(0, i - m), hi = min(c - 1, i + m)
            let chord = dist(nodes[lo], nodes[hi])
            let localSinu = chord > 1e-9 ? (cum[hi] - cum[lo]) / chord : 1
            let sat = s1 > s0 ? max(0, min(1, (s1 - localSinu) / (s1 - s0))) : 1
            // −eff: zum Außenufer (weg vom Krümmungszentrum), wie `lateralStep`.
            var er = g.mob[i]
            var r = -e * b * (b * eff) * er * sat
            // Talwand-Bremse: liegt das Gelände ein paar Breiten weiter in
            // Bewegungsrichtung deutlich über der Linie (über
            // `meanderBeltBrakeDepths` Rinnentiefen), hält der Lauf — Hügel und
            // Talflanken begrenzen den Gürtel, Unebenheiten der Aue nicht.
            // Rinnentiefe: die von `channelCarve`, mindestens die Kanaltiefe.
            // Gemessen verworfen: Ufer gegen gegenüberliegendes Ufer direkt am
            // Kanal — das reagierte auf jedes sanfte Quergefälle und hielt die
            // Linie gerade (Sinuosität 1,1–1,2); ganz ohne Bremse lief der Lauf
            // über die Ebene ins Knäuel.
            if r != 0 {
                let dref = max(1e-9, config.meanderBeltDepthPerWidth * config.cellSize * b,
                               config.channelTargetDepth)
                let dir = r > 0 ? 1.0 : -1.0
                let far = 0.5 * b + 3 * b
                let wall = heightAt(MeanderNode(x: nodes[i].x + dir * g.nx[i] * far,
                                                z: nodes[i].z + dir * g.nz[i] * far))
                let over = max(0, (wall - heightAt(nodes[i])) / dref - config.meanderBeltBrakeDepths)
                r /= 1 + over * over
                er /= 1 + over * over
            }
            erod[i] = er
            rate[i] = r
        }
        // Die Gesamtrate längs über ±½ Breite glätten: je Knoten verschiedene
        // Bremsfaktoren verschoben Nachbarknoten ungleich; der entstehende
        // Zickzack im Knotenabstand liegt unter der Krümmungs-Skala (±½
        // Breite), der negative Lokalterm sah ihn nicht, und seine
        // Knick-Krümmung trieb die CFL-Teilschritte gemessen in den Deckel.
        var out = rate
        for i in 1..<max(1, c - 1) {
            let kr = max(1, Int((0.5 * g.width[i] / sp).rounded()))
            var accR = 0.0
            let lr = max(1, i - kr), hr = min(c - 2, i + kr)
            for j in lr...hr { accR += rate[j] }
            out[i] = accR / Double(hr - lr + 1)
        }
        return (out, erod)
    }

    struct BeltFootprint {
        let minX: Double, maxX: Double, minZ: Double, maxZ: Double
        let maxSubsteps: Int
        func overlaps(_ other: BeltFootprint) -> Bool {
            minX <= other.maxX && other.minX <= maxX && minZ <= other.maxZ && other.minZ <= maxZ
        }
    }

    /// Geländeunabhängige Schranke der ANFÄNGLICHEN Rate. Mobilität,
    /// Sättigung und Talwand-Bremse liegen in 0…1. Vor der Ratenglättung
    /// Beträge zu nehmen begrenzt auch jede mögliche Auslöschung von Vorzeichen.
    /// Die einmal gewählte Teilschrittzahl bleibt im gesamten Lauf konstant.
    func beltFootprint(_ ch: RiverChannel, dt: Double, config: SimConfig) -> BeltFootprint? {
        guard ch.nodes.count >= 3, dt > 0, dt.isFinite, config.meanderNodeSpacing > 0,
              config.meanderBeltRate >= 0 else { return nil }
        let g = Self.beltGeometry(ch, config: config, heightAt: { _ in config.sea + 1 })
        let (rates, _) = beltRatesAndErodibility(ch, g, config: config, heightAt: { _ in config.sea + 1 }, boundOnly: true)
        let rate = rates.reduce(0) { max($0, abs($1)) }
        let needed = (rate * 1.001 * dt / (0.5 * config.meanderNodeSpacing)).rounded(.up)
        guard needed.isFinite else { return nil }
        let substeps = max(1, Int(min(4096, needed)))
        let width = (g.width.max() ?? 0) * 1.001
        // Explizite Bewegung UND Störung: jeweils <= ½ Knotenabstand.
        // Implizite Diffusion (nichtnegative Koeffizienten), Cutoff und Resample
        // bleiben in der konvexen Hülle. Zwei Zellen decken Rundung, bilineare
        // Abfragen und die vier Nachbarn der Altarm-Pfropfen ab.
        let radius = Double(substeps) * config.meanderNodeSpacing
            + max(3.5, 0.5 + config.meanderBarWidths) * width + 2
        guard radius.isFinite, ch.nodes.allSatisfy({
            $0.x.isFinite && $0.z.isFinite && $0.x >= 0 && $0.z >= 0
                && $0.x <= Double(config.n - 1) && $0.z <= Double(config.n - 1)
        }) else { return nil }
        return BeltFootprint(minX: ch.nodes.map(\.x).min()! - radius, maxX: ch.nodes.map(\.x).max()! + radius,
                             minZ: ch.nodes.map(\.z).min()! - radius, maxZ: ch.nodes.map(\.z).max()! + radius,
                             maxSubsteps: substeps)
    }

    /// Gemeinsame Historie erst nach allen Arbeiten in ursprünglicher Lauf-Reihenfolge.
    func appendBeltHistory(_ run: MeanderState) {
        oxbows.append(contentsOf: run.oxbows)
        oxbowAge.append(contentsOf: run.oxbowAge)
        neckCutoffs += run.neckCutoffs
        chuteCutoffs += run.chuteCutoffs
    }

    struct BeltMigrationPlan {
        var rate: Double
        var g: BeltGeometry
        var r: [Double]
        var erod: [Double]
    }

    /// Berechnet Geometrie und Raten für die Zeitschritt-Schätzung und hält das
    /// Ergebnis fest, damit Teilschritt 0 dieselbe Arbeit nicht wiederholt.
    func beltMigrationPlan(channel ci: Int, config: SimConfig,
                           heightAt: (MeanderNode) -> Double) -> BeltMigrationPlan {
        let ch = channels[ci]
        guard ch.nodes.count >= 3, Self.migrates(ch, config) else {
            let empty = BeltGeometry(width: [], curv: [], nx: [], nz: [], mob: [])
            return BeltMigrationPlan(rate: 0, g: empty, r: [], erod: [])
        }
        let g = Self.beltGeometry(ch, config: config, minDischarge: config.meanderBeltMinCells, heightAt: heightAt)
        let (r, erod) = beltRatesAndErodibility(ch, g, config: config, heightAt: heightAt)
        let maxRate = r.reduce(0) { max($0, abs($1)) }
        return BeltMigrationPlan(rate: maxRate, g: g, r: r, erod: erod)
    }

    /// Größte Verschiebungsrate EINES Laufs (Zellen/Jahr) — seine eigene
    /// CFL-Teilschrittzahl (`Terrain.meanderBeltStep`).
    func beltMaxRate(channel ci: Int, config: SimConfig, heightAt: (MeanderNode) -> Double) -> Double {
        beltMigrationPlan(channel: ci, config: config, heightAt: heightAt).rate
    }

    /// Wendet einen fertigen Migrationsplan (aus `beltMigrationPlan`) bit-identisch an,
    /// ohne `beltGeometry` und Raten erneut zu berechnen.
    func applyBeltMigrationPlan(_ ci: Int, plan: BeltMigrationPlan, dt: Double, time: Double, config: SimConfig,
                                noiseChannel: Int? = nil) {
        let spacing = config.meanderNodeSpacing
        let maxStep = 0.5 * spacing
        let kappaK = abs(config.meanderBeltLocalWeight) * config.meanderBeltRate / max(1e-12, spacing * spacing)
        var ch = channels[ci]
        let g = plan.g, r = plan.r, erod = plan.erod
        if ch.nodes.count >= 3 {
            if let firstR = r.firstIndex(where: { $0 != 0 }),
               let lastR = r.lastIndex(where: { $0 != 0 }) {
                for i in firstR...lastR where r[i] != 0 {
                    let m = max(-maxStep, min(maxStep, r[i] * dt))
                    ch.nodes[i].x += m * g.nx[i]; ch.nodes[i].z += m * g.nz[i]
                }
            }
            Self.perturb(&ch.nodes, g, erod, dt: dt, time: time, channel: noiseChannel ?? ci,
                         config: config, maxStep: maxStep)
            let c = ch.nodes.count
            var a = [Double](repeating: 0, count: c)
            if let firstE = erod.firstIndex(where: { $0 > 0 }),
               let lastE = erod.lastIndex(where: { $0 > 0 }) {
                for i in firstE...lastE where erod[i] > 0 {
                    let b = g.width[i]
                    a[i] = kappaK * b * b * erod[i] * dt
                }
                ch.nodes = Self.implicitDiffuse(ch.nodes, a)
            }
        }
        applyBeltCutoffs(&ch, config: config)
        ch = resample(ch, spacing: spacing)
        channels[ci] = ch
    }

    /// Ein Teilschritt für EINEN Lauf über `dt` Jahre: Verschiebung, Störung,
    /// Glättung (implizit), Cutoffs (Hals und Chute), Resample. Der Aufrufer
    /// taktet so, dass kein Knoten mehr als einen halben Knotenabstand springt;
    /// die Klemme hier ist nur Sicherheitsnetz. Altarm-Alter setzt der Aufrufer.
    func migrateBeltChannel(_ ci: Int, dt: Double, time: Double, config: SimConfig,
                            heightAt: (MeanderNode) -> Double, geometry: BeltGeometry? = nil, noiseChannel: Int? = nil) {
        let spacing = config.meanderNodeSpacing
        let maxStep = 0.5 * spacing
        let kappaK = abs(config.meanderBeltLocalWeight) * config.meanderBeltRate / max(1e-12, spacing * spacing)
        var ch = channels[ci]
        if ch.nodes.count >= 3 {
            var g: BeltGeometry
            if let geometry {
                g = geometry
                Self.updateBeltMobility(&g, ch, config: config, minDischarge: config.meanderBeltMinCells, heightAt: heightAt)
            } else {
                g = Self.beltGeometry(ch, config: config, minDischarge: config.meanderBeltMinCells, heightAt: heightAt)
            }
            let (r, erod) = beltRatesAndErodibility(ch, g, config: config, heightAt: heightAt)
            if let firstR = r.firstIndex(where: { $0 != 0 }),
               let lastR = r.lastIndex(where: { $0 != 0 }) {
                for i in firstR...lastR where r[i] != 0 {
                    let m = max(-maxStep, min(maxStep, r[i] * dt))
                    ch.nodes[i].x += m * g.nx[i]; ch.nodes[i].z += m * g.nz[i]
                }
            }
            Self.perturb(&ch.nodes, g, erod, dt: dt, time: time, channel: noiseChannel ?? ci,
                         config: config, maxStep: maxStep)
            let c = ch.nodes.count
            var a = [Double](repeating: 0, count: c)
            if let firstE = erod.firstIndex(where: { $0 > 0 }),
               let lastE = erod.lastIndex(where: { $0 > 0 }) {
                for i in firstE...lastE where erod[i] > 0 {
                    let b = g.width[i]
                    a[i] = kappaK * b * b * erod[i] * dt
                }
                ch.nodes = Self.implicitDiffuse(ch.nodes, a)
            }
        }
        applyBeltCutoffs(&ch, config: config)
        ch = resample(ch, spacing: spacing)
        channels[ci] = ch
    }

    /// Zubringer bleiben an ihrem Vorfluter: jeder Lauf ist eine eigene
    /// Zentrumslinie, und `traceChannels` beendet einen Zubringer an der Zelle,
    /// an der er auf einen schon gezogenen Lauf trifft. Wandern beide, liefen sie
    /// gemessen als zwei, drei parallele Bänder durch denselben Gürtel zum Meer.
    /// Deshalb: kommt ein Lauf einem GRÖSSEREN (Abfluss am Ende) näher als
    /// die halbe Summe beider Breiten, endet er dort, und sein Endknoten sitzt
    /// auf dem nächsten Knoten des Vorfluters — auch in den folgenden
    /// Schritten (der Aufruf läuft EINMAL je Schritt, nach allen
    /// Teilschritten), solange der Vorfluter in Reichweite (zwei Breiten)
    /// bleibt. „Abfluss am Ende" ist seit der Kopplung (#187) der EIGENE: die
    /// Mündungszelle zählt dort zum größeren Fluss.
    func attachTributaries(config: SimConfig) {
        let cell = 8.0
        // Nachschlagen auf einer unveränderten Kopie: das Kürzen eines Laufs
        // unten darf die Indizes im Gitter nicht ungültig machen. Flaches
        // Bin-Gitter statt Dictionary (Allokationen, s. `applyBeltCutoffs`).
        let snap = channels
        let gw = max(1, Int(Double(config.n) / cell) + 3)
        var head = [Int32](repeating: -1, count: gw * gw)
        var flatC: [Int32] = [], flatN: [Int32] = [], next: [Int32] = []
        @inline(__always) func bin(_ v: Double) -> Int { min(gw - 1, max(0, Int(v / cell) + 1)) }
        // Mit Kopplung (#187) enden feste Läufe ohnehin an ihrem
        // D8-Zusammenfluss; neu heranrücken kann nur ein WANDERNDER Vorfluter.
        // Nur seine Knoten kommen ins Gitter (gemessen 2,9 ms je Schritt, als
        // jeder Knoten jedes Laufs gegen alle Läufe geprüft wurde).
        let mobileTargets = config.meanderBelt && config.meanderBeltCoupling
        for (ci, ch) in snap.enumerated() where !mobileTargets || Self.migrates(ch, config) {
            for (ni, p) in ch.nodes.enumerated() {
                let b = bin(p.z) * gw + bin(p.x)
                next.append(head[b]); head[b] = Int32(flatC.count)
                flatC.append(Int32(ci)); flatN.append(Int32(ni))
            }
        }
        func nearestBigger(_ ci: Int, _ p: MeanderNode, _ q: Double, _ reach: (Double) -> Double)
            -> (MeanderNode, Double)? {
            var best: (MeanderNode, Double)? = nil
            let bx = bin(p.x), bz = bin(p.z)
            let qaEnd = snap[ci].discharge.last ?? 0
            for zz in max(0, bz - 2)...min(gw - 1, bz + 2) {
                for xx in max(0, bx - 2)...min(gw - 1, bx + 2) {
                    var e = head[zz * gw + xx]
                    while e >= 0 {
                        let cj = Int(flatC[Int(e)]), nj = Int(flatN[Int(e)]); e = next[Int(e)]
                        guard cj != ci, nj < snap[cj].nodes.count - 3 else { continue }
                        // Größer = der GANZE Lauf führt mehr (Abfluss am Ende). Der
                        // Abfluss an der Stelle taugt nicht: der Endknoten eines
                        // Zubringers liegt auf der Mündungszelle und trägt den
                        // Abfluss des Vorfluters — so zerhackte der Vergleich
                        // gemessen jeden Hauptlauf an jedem Zusammenfluss. Aus
                        // demselben Grund zählen die letzten Knoten nicht als Ziel.
                        let qbEnd = snap[cj].discharge.last ?? 0
                        guard qbEnd > qaEnd || (qbEnd == qaEnd && cj < ci) else { continue }
                        let o = snap[cj].nodes[nj]
                        let d = dist(p, o)
                        let bB = Self.beltWidthCells(discharge: snap[cj].discharge[nj], config: config)
                        if d < reach(bB), best == nil || d < best!.1 { best = (o, d) }
                    }
                }
            }
            return best
        }
        for ci in channels.indices {
            let ch = channels[ci]
            let c = ch.nodes.count
            guard c >= 3 else { continue }
            // Mündung in einen größeren Lauf: erster Knoten (ab Index 2) in Reichweite.
            for j in 2..<c {
                let q = ch.discharge[j]
                let bA = Self.beltWidthCells(discharge: q, config: config)
                if let (o, _) = nearestBigger(ci, ch.nodes[j], q, { 0.5 * (bA + $0) }) {
                    var nodes = Array(ch.nodes[0...j]), dis = Array(ch.discharge[0...j])
                    nodes[j] = o; dis[j] = q
                    if j + 1 < c || nodes[j] != ch.nodes[j] {
                        channels[ci] = RiverChannel(nodes: nodes, discharge: dis)
                    }
                    break
                }
                if j == c - 1, let (o, _) = nearestBigger(ci, ch.nodes[j], q, { 2 * $0 }) {
                    channels[ci].nodes[j] = o   // angeschlossenes Ende folgt dem Vorfluter
                }
            }
        }
    }

    /// Störquelle des Kerns (Howard & Knutson 1984: zufällige Auslenkung der
    /// Knoten je Zeitschritt). Howard–Knutson ist KONVEKTIV instabil: Bögen
    /// wachsen und wandern stromab, eine einmal gerade Strecke bleibt gerade.
    /// Ohne Störquelle spülte der Kern seine Anfangszacken in ~60.000 Jahren
    /// hinaus und lag danach als gerade Linie mit einer Spirale am festen Ende
    /// da (gemessen: Sinuosität 1,00 ab Jahr 62.000, `testBeltKernelDiagnostic`).
    /// In echten Auen kommt die Störung aus der Heterogenität der Ufer
    /// (Tonpfropfen alter Altarme, Bewuchs, Zubringer).
    ///
    /// Auslenkung je Knoten `A · b · √(Rate · dt) · ξ` mit ξ ~ Einheitsvarianz,
    /// über ±½ Breite geglättet (Knotenzacken dämpft der Lokalterm ohnehin weg)
    /// und mit der Erodierbarkeit gewichtet (feste Strecken zittern nicht).
    /// Varianz ∝ dt: in Verteilung schrittweiten-unabhängig (Wiener-Prozess),
    /// nicht pfadgleich. ξ ist ein Hash aus Zeit, Lauf und Knoten —
    /// deterministisch und nach `restore` reproduzierbar, ohne neuen Zustand.
    static func perturb(_ nodes: inout [MeanderNode], _ g: BeltGeometry, _ erod: [Double],
                        dt: Double, time: Double, channel ci: Int, config: SimConfig, maxStep: Double) {
        let amp = config.meanderBeltNoise
        let c = nodes.count
        guard amp > 0, dt > 0, c >= 3 else { return }
        let sp = max(1e-6, config.meanderNodeSpacing)
        guard let firstE = erod.firstIndex(where: { $0 > 0 }),
              let lastE = erod.lastIndex(where: { $0 > 0 }) else { return }
        let key = time.bitPattern &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: ci) &* 0xD1B5_4A32_D192_ED03
        var xi = [Double](repeating: 0, count: c)
        for i in firstE...lastE where erod[i] > 0 { xi[i] = 3.0.squareRoot() * hashUnit(key, i) }
        let base = amp * (config.meanderBeltRate * dt).squareRoot()
        for i in firstE...lastE where erod[i] > 0 {
            let kr = max(1, Int((0.5 * g.width[i] / sp).rounded()))
            let lo = max(1, i - kr), hi = min(c - 2, i + kr)
            var acc = 0.0
            for j in lo...hi { acc += xi[j] }
            let cnt = Double(hi - lo + 1)
            let m = max(-maxStep, min(maxStep, base * g.width[i] * erod[i] * acc / cnt.squareRoot()))
            nodes[i].x += m * g.nx[i]; nodes[i].z += m * g.nz[i]
        }
    }

    /// Gleichverteilt in [−1, 1) aus (Schlüssel, Index), SplitMix64-Finalisierer.
    @inline(__always) static func hashUnit(_ key: UInt64, _ i: Int) -> Double {
        var z = key &+ UInt64(truncatingIfNeeded: i) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }

    /// Löst `−aᵢ·xᵢ₋₁ + (1 + 2aᵢ)·xᵢ − aᵢ·xᵢ₊₁ = xᵢ(alt)` für beide Koordinaten
    /// (Thomas-Algorithmus), Endknoten fest. `a` = κ·dt/ds² je Knoten.
    static func implicitDiffuse(_ nodes: [MeanderNode], _ a: [Double]) -> [MeanderNode] {
        let c = nodes.count
        guard c >= 3 else { return nodes }
        guard let firstA = a.firstIndex(where: { $0 > 0 }),
              let lastA = a.lastIndex(where: { $0 > 0 }) else { return nodes }
        // Da Zeilen mit a[i] == 0 exakte Identitätszeilen sind (lo=0, di=1, up=0 -> cp=0, dx=nodes[i]),
        // entkoppelt das System an den Rändern: firstA - 1 und lastA + 1 wirken als feste Dirichlet-Ränder.
        var cp = [Double](repeating: 0, count: lastA + 1)
        var dx = [Double](repeating: 0, count: lastA + 1)
        var dz = [Double](repeating: 0, count: lastA + 1)
        cp[firstA - 1] = 0
        dx[firstA - 1] = nodes[firstA - 1].x
        dz[firstA - 1] = nodes[firstA - 1].z
        for i in firstA...lastA {
            let lo = -a[i], di = 1 + 2 * a[i], up = -a[i]
            let m = di - lo * cp[i - 1]
            cp[i] = up / m
            dx[i] = (nodes[i].x - lo * dx[i - 1]) / m
            dz[i] = (nodes[i].z - lo * dz[i - 1]) / m
        }
        var out = nodes
        for i in stride(from: lastA, through: firstA, by: -1) {
            out[i].x = dx[i] - cp[i] * out[i + 1].x
            out[i].z = dz[i] - cp[i] * out[i + 1].z
        }
        return out
    }

    /// Hals-Cutoff (Halsweite unter `meanderBeltNeckWidths` Kanalbreiten) und
    /// Chute-Cutoff (Sehne unter `meanderChuteWidths` Breiten, Schleife
    /// mindestens `meanderChuteLoopRatio`-mal länger, Abfluss ab
    /// `meanderChuteMinCells`). Früheste Abschnürung zuerst, wie `applyCutoffs`.
    private func applyBeltCutoffs(_ ch: inout RiverChannel, config: SimConfig) {
        let spacing = max(1e-6, config.meanderNodeSpacing)
        var guardN = 0
        while guardN < 64, ch.nodes.count >= 4 {
            guardN += 1
            let nodes = ch.nodes, c = nodes.count
            var cum = [Double](repeating: 0, count: c)
            for i in 1..<c { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
            var widths = [Double](repeating: 0, count: c)
            var maxReach = 0.0                                 // größte Prüfweite
            for i in 0..<c {
                let b = Self.beltWidthCells(discharge: ch.discharge[i], config: config)
                widths[i] = b
                let neck = max(config.meanderNeckDist, config.meanderBeltNeckWidths * b)
                let chute = ch.discharge[i] >= config.meanderChuteMinCells ? config.meanderChuteWidths * b : 0
                maxReach = max(maxReach, max(neck, chute))
            }
            guard maxReach > 0, maxReach.isFinite else { return }
            // Flaches Bin-Gitter (Kantenlänge maxReach, verkettete Listen):
            // Kandidaten nur aus den 3×3 Nachbar-Bins. Ein Dictionary allokierte
            // je Lauf und Teilschritt und trug den Großteil der Gürtel-Kosten.
            // Puffer wiederverwendet (Review #187: je Aufruf, also je Lauf und
            // Teilschritt, neu allokiert); zurückgesetzt werden nur die
            // belegten Bins. Reihenfolge der Listen unverändert.
            let gw = max(1, Int(Double(config.n) / maxReach) + 3)
            if cutBinHead.count < gw * gw { cutBinHead = [Int32](repeating: -1, count: gw * gw) }
            for b in cutBinTouched { cutBinHead[Int(b)] = -1 }
            cutBinTouched.removeAll(keepingCapacity: true)
            if cutBinNext.count < c { cutBinNext = [Int32](repeating: -1, count: c) }
            @inline(__always) func bin(_ v: Double) -> Int { min(gw - 1, max(0, Int(v / maxReach) + 1)) }
            for i in 0..<c {
                let b = bin(nodes[i].z) * gw + bin(nodes[i].x)
                if cutBinHead[b] < 0 { cutBinTouched.append(Int32(b)) }
                cutBinNext[i] = cutBinHead[b]; cutBinHead[b] = Int32(i)
            }
            var cut: (Int, Int, Bool)? = nil
            outer: for i in 0..<c {
                let b = widths[i]
                let neck = max(config.meanderNeckDist, config.meanderBeltNeckWidths * b)
                let chute = ch.discharge[i] >= config.meanderChuteMinCells ? config.meanderChuteWidths * b : 0
                let minSep = max(4, Int(neck / spacing * 3) + 2)
                let maxLoop = config.meanderBeltMaxLoopWidths * b
                let bx = bin(nodes[i].x), bz = bin(nodes[i].z)
                var best: (Int, Bool)? = nil
                for zz in max(0, bz - 1)...min(gw - 1, bz + 1) {
                    for xx in max(0, bx - 1)...min(gw - 1, bx + 1) {
                        var jj = cutBinHead[zz * gw + xx]
                        while jj >= 0 {
                            let j = Int(jj); jj = cutBinNext[j]
                            guard j >= i + minSep, best == nil || j < best!.0,
                                  cum[j] - cum[i] <= maxLoop else { continue }
                            let d = dist(nodes[i], nodes[j])
                            if d < neck { best = (j, false) }
                            else if d < chute && cum[j] - cum[i] >= config.meanderChuteLoopRatio * d {
                                best = (j, true)
                            }
                        }
                    }
                }
                if let (j, isChute) = best { cut = (i, j, isChute); break outer }
            }
            guard let (i, j, isChute) = cut else { break }
            if isChute { chuteCutoffs += 1 } else { neckCutoffs += 1 }
            oxbows.append(Array(ch.nodes[i...j]))
            oxbowAge.append(0)
            var newNodes = Array(ch.nodes[0...i]); newNodes.append(contentsOf: ch.nodes[j...])
            var newDis = Array(ch.discharge[0...i]); newDis.append(contentsOf: ch.discharge[j...])
            ch = RiverChannel(nodes: newNodes, discharge: newDis)
        }
    }
}

@inline(__always) func dist(_ a: MeanderNode, _ b: MeanderNode) -> Double {
    let dx = a.x - b.x, dz = a.z - b.z
    return (dx * dx + dz * dz).squareRoot()
}
